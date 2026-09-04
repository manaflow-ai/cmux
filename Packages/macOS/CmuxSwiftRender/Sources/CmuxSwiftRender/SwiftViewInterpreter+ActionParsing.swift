import SwiftSyntax

extension SwiftViewInterpreter {
    /// Captures a closure's command calls, evaluating argument expressions
    /// against the closure environment so loop-captured values are baked in.
    func parseAction(_ closure: ClosureExprSyntax, _ env: EvalEnvironment) -> ButtonAction {
        var commands: [ActionCommand] = []
        for item in closure.statements {
            guard let call = item.item.as(ExprSyntax.self)?.as(FunctionCallExprSyntax.self),
                  let name = actionCallName(call.calledExpression) else { continue }

            func value(_ arg: LabeledExprSyntax) -> String {
                expressions.eval(arg.expression, env)?.actionParameterString
                    ?? arg.expression.trimmedDescription
            }

            switch name {
            case "cmux":
                var method: String?
                var params: [String: String] = [:]
                for arg in call.arguments {
                    if let label = arg.label?.text {
                        params[label] = value(arg)
                    } else if method == nil {
                        method = value(arg)
                    }
                }
                if let method {
                    commands.append(.cmux(method: method, params: params))
                }
            case "log" where !call.arguments.isEmpty:
                commands.append(.log(value(call.arguments.first!)))
            case "openURL" where !call.arguments.isEmpty:
                commands.append(.openURL(value(call.arguments.first!)))
            default:
                // Qualified calls (`workspace.create(...)`) are shorthand for
                // the same dispatcher command as `cmux("workspace.create", ...)`.
                guard name == "workspace.create" else { continue }
                var params: [String: String] = [:]
                for arg in call.arguments {
                    guard let label = arg.label?.text else { continue }
                    params[label] = value(arg)
                }
                commands.append(.cmux(method: name, params: params))
            }
        }
        return ButtonAction(commands: commands)
    }

    /// Returns the closure's declared parameter names, including both closure
    /// parameter syntaxes accepted by SwiftParser.
    func closureParameterNames(_ closure: ClosureExprSyntax) -> [String] {
        guard let parameterClause = closure.signature?.parameterClause else { return [] }
        if case let .simpleInput(list) = parameterClause {
            return list.map { $0.name.text }
        }
        if case let .parameterClause(clause) = parameterClause {
            return clause.parameters.map { $0.firstName.text }
        }
        return []
    }

    /// Returns the dotted name of an action call such as `workspace.create`.
    ///
    /// Interpreted sidebars historically used `cmux("method", ...)`; accepting
    /// a qualified call as well keeps the source syntax close to the command
    /// names shown in the API documentation while lowering to the same action
    /// IR.
    func actionCallName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              let base = member.base,
              let prefix = actionCallName(base) else {
            return nil
        }
        return "\(prefix).\(member.declName.baseName.text)"
    }
}
