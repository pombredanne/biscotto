fs           = require 'fs'
path         = require 'path' # To load package.json

_            = require 'underscore'
builtins     = require 'builtins'

# TODO:
#
# - [x] add `paramNames` for functions
# - [x] convert `objects` to line numbers (and in the exports section)
# - [x] tag builtin NodeJs modules : https://github.com/segmentio/builtins
# - [x] add `classProperties` and `prototypeProperties`
# - [x] add doc string
# - [x] look up version numbers for modules

module.exports = class Visitor
  packageFile: JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf-8'))

  constructor: (@fileName, @classes, root, @lineMapping) ->
    @defs = {} # Local variable definitions
    @exports = {}
    @commentLines = {}

    root.traverseChildren no, (exp) => @visit(exp) # `no` means Stop at scope boundaries

  visit: (exp) ->
    # throw new Error "Could not parse line #{lineMapping[exp.locationData.first_line]} because of missing visit#{exp.constructor.name}()" unless @["visit#{exp.constructor.name}"]
    @["visit#{exp.constructor.name}"](exp)
  eval:  (exp) ->
    # throw new Error "Could not parse line #{lineMapping[exp.locationData.first_line]} because of missing eval#{exp.constructor.name}()" unless @["eval#{exp.constructor.name}"]
    @["eval#{exp.constructor.name}"](exp)

  visitComment: (exp) ->
    # Skip the 1st comment which is added by coffeescript
    return if exp.comment is '~Private~'

    @commentLines[@lineMapping[exp.locationData.last_line]] = exp.comment.trim()

  visitClass: (exp) ->
    return unless exp.variable?
    @defs[exp.variable.base.value] = @evalClass(exp)
    no # Do not traverse into the class methods

  visitAssign: (exp) ->
    variable = @eval(exp.variable)
    value = @eval(exp.value)

    baseName = exp.variable.base.value
    switch baseName
      when 'module'
        return if exp.variable.properties.length is 0 # Ignore `module = ...` (atom/src/browser/main.coffee)
        unless exp.variable.properties?[0]?.name?.value is 'exports'
          # console.log _.map variable.properties, (item) -> item.name.value
          throw new Error 'BUG: Does not support module.somthingOtherThanExports'
        baseName = 'exports'
        firstProp = exp.variable.properties[1]
      when 'exports'
        firstProp = exp.variable.properties[0]

    switch baseName
      when 'exports'
        # Handle 3 cases:
        #
        # - `exports.foo = SomeClass`
        # - `exports.foo = 42`
        # - `exports = bar`
        if firstProp
          return unless value.base?
          if @defs[value.base.value]
            # case `exports.foo = SomeClass`
            @exports[firstProp.name.value] = @defs[value.base.value]
          else
            # case `exports.foo = 42`
            @exports[firstProp.name.value] =
              type: 'primitive'
              doc: @commentLines[@lineMapping[value.locationData.first_line] - 1]
              startLineNumber:  value.locationData.first_line
              endLineNumber:    value.locationData.last_line
              startColNumber:  value.locationData.first_column
              endColNumber:    value.locationData.last_column

        else
          # case `exports = bar`
          @exports = {_default: value}

      # case left-hand-side is anything other than `exports...`
      else
        # Handle 4 common cases:
        #
        # X     = ...
        # {X}   = ...
        # {X:Y} = ...
        # X.y   = ...
        switch exp.variable.base.constructor.name
          when 'Literal'
            # case _.str = ...
            if exp.variable.properties.length > 0
              nameWithPeriods = [exp.variable.base.value].concat(_.map(exp.variable.properties, (prop) -> prop.name.value)).join(".")
              @defs[nameWithPeriods] = _.extend name: nameWithPeriods, value
            else # case X = ...
              # console.log exp.variable.base.value
              @defs[exp.variable.base.value] = _.extend name: exp.variable.base.value, value
          when 'Obj'
            for key in exp.variable.base.objects
              switch key.constructor.name
                when 'Value'
                  # case {X} = ...
                  @defs[key.base.value] = _.extend {}, value,
                    name: key.base.value
                    exportsProperty: key.base.value

                when 'Assign'
                  # case {X:Y} = ...
                  @defs[key.value.base.value] = _.extend {}, value,
                    name: key.value.base.value
                    exportsProperty: key.variable.base.value
                  return no # Do not continue visiting X

                else throw new Error "BUG: Unsupported require Obj structure: #{key.constructor.name}"

          else throw new Error "BUG: Unsupported require structure: #{variable.base.constructor.name}"

  visitCode: (exp) ->

  visitValue: (exp) ->

  visitCall: (exp) ->

  visitLiteral: (exp) ->

  visitObj: (exp) ->

  visitAccess: (exp) ->

  visitBlock: (exp) ->

  evalComment: (exp) ->

  evalClass: (exp) ->
    className = exp.variable.base.value
    classProperties = []
    prototypeProperties = []

    for subExp in exp.body.expressions

      switch subExp.constructor.name
        # case Prototype-level methods (this.foo = (foo) -> ...)
        when 'Assign'
          value = @eval(subExp.value)
          # value.paramNames = value.paramNames
          # console.log subExp.value.constructor.name
          # console.log subExp.params
          # value =
          #   name: property.name.value
          #   type: "classProperty"
          #   doc: null
          #   startLineNumber: property.locationData.first_line + 1
          #   endLineNumber: property.locationData.last_line + 1
          @defs["#{className}.#{value.name}"] = value
          classProperties.push(value)
        when 'Value'
          # case Prototype-level properties (@foo: "foo")
          for prototypeExp in subExp.base.properties

            switch prototypeExp.constructor.name
              when 'Comment'
                continue
              else
                isClassLevel = prototypeExp.variable.this

                if isClassLevel
                  name = prototypeExp.variable.properties[0].name.value
                else
                  name = prototypeExp.variable.base.value

                # Do not include the class constructor
                continue if name is 'constructor'

                value = @eval(prototypeExp.value)

                if value.constructor?.name is 'Value'
                  lookedUpVar = @defs[value.base.value]
                  if lookedUpVar
                    if lookedUpVar.type is 'import'
                      value =
                        name: name
                        doc: @commentLines[@lineMapping[value.locationData.first_line] - 1]
                        startLineNumber: value.locationData.first_line
                        endLineNumber: value.locationData.last_line
                        startColNumber:  value.locationData.first_column
                        endColNumber:    value.locationData.last_column
                        reference: lookedUpVar
                    else
                      value = _.extend name: name, lookedUpVar

                  else
                    # Assigning a simple var
                    value =
                      type: 'primitive'
                      name: name
                      doc: @commentLines[@lineMapping[value.locationData.first_line] - 1]
                      startLineNumber:  value.locationData.first_line
                      endLineNumber:    value.locationData.last_line
                      startColNumber:  value.locationData.first_column
                      endColNumber:    value.locationData.last_column

                else
                  value = _.extend name: name, value


                # TODO: `value = @eval(prototypeExp.value)` is messing this up
                # interferes also with evalValue
                if isClassLevel
                  value.name = name
                  value.type = "classProperty"
                  @defs["#{className}.#{name}"] = value
                  classProperties.push(value)
                else
                  value.name = name
                  value.type = "prototypeProperty"
                  @defs["#{className}::#{name}"] = value
                  prototypeProperties.push(value)
          true

    # find the matching class from the parsed file
    clazz = _.find(@classes, (clazz) -> clazz.getFullName() == className)

    type: 'class'
    name: className
    classProperties: classProperties
    prototypeProperties: prototypeProperties
    doc: if clazz? then clazz.doc.node.comment else null
    startLineNumber:  exp.locationData.first_line
    endLineNumber:    exp.locationData.last_line
    startColNumber:  exp.locationData.first_column
    endColNumber:    exp.locationData.last_column

  evalCode: (exp) ->
    bindingType: 'variable'
    type: 'function'
    paramNames: _.map exp.params, (param) -> param.name.value
    doc: @commentLines[@lineMapping[exp.locationData.first_line] - 1]
    startLineNumber:  exp.locationData.first_line
    endLineNumber:    exp.locationData.last_line
    startColNumber:  exp.locationData.first_column
    endColNumber:    exp.locationData.last_column

  evalValue: (exp) ->
    if exp.base
      type: 'primitive'
      name: exp.base?.value
      doc: @commentLines[@lineMapping[exp.locationData.first_line] - 1]
      startLineNumber: exp.locationData.first_line
      endLineNumber:   exp.locationData.last_line
      startColNumber:  exp.locationData.first_column
      endColNumber:    exp.locationData.last_column
    else
      throw new Error 'BUG? Not sure how to evaluate this value if it does not have .base'

  evalCall: (exp) ->
    # The only interesting call is `require('foo')`
    if exp.variable.base.value is 'require'
      moduleName = exp.args[0].base.value
      moduleName = moduleName.substring(1, moduleName.length - 1)

      # For npm modules include the version number
      ver = @packageFile.dependencies[moduleName]
      moduleName = "#{moduleName}@#{ver}" if ver

      ret =
        type: 'import'
        doc: @commentLines[@lineMapping[exp.locationData.first_line] - 1]
        startLineNumber:  exp.locationData.first_line
        endLineNumber:    exp.locationData.first_line
        startColNumber:  exp.locationData.first_column
        endColNumber:    exp.locationData.last_column

      if /^\./.test(moduleName)
        # Local module
        ret.path = moduleName
      else
        ret.module = moduleName
      # Tag builtin NodeJS modules
      ret.builtin = true if builtins.indexOf(moduleName) >= 0

      ret

    else
      type: 'function'
      doc: @commentLines[@lineMapping[exp.locationData.first_line] - 1]
      startLineNumber:  exp.locationData.first_line
      endLineNumber:    exp.locationData.last_line
      startColNumber:  exp.locationData.first_column
      endColNumber:    exp.locationData.last_column

  evalError: (str, exp) ->
    throw new Error "BUG: Not implemented yet: #{str}. Line #{exp.locationData.first_line}"

  evalAssign: (exp) -> @eval(exp.value) # Support x = y = z

  evalLiteral: (exp) -> @evalError 'evalLiteral', exp

  evalObj: (exp) -> @evalError 'evalObj', exp

  evalAccess: (exp) -> @evalError 'evalAccess', exp

  evalUnknown: (exp) -> exp
  evalIf: -> @evalUnknown(arguments)
  visitIf: ->
  visitOp: ->
  visitArr: ->
  visitNull: ->
  visitBool: ->
  visitIndex: ->
  visitParens: ->

  evalOp: (exp) -> exp