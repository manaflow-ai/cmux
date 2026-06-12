import Foundation
import SwiftSyntax

/// User-defined value-returning function evaluation: parameter binding and
/// block/if/switch value semantics for interpreted `func` bodies, closures,
/// and value-position control flow.
extension ExpressionEvaluator {
    // MARK: - User functions (value-returning)

    /// Binds a call's arguments (by position) to a function's parameters in a
    /// fresh child scope, evaluating each argument in the caller's scope.
    func bindParameters(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> EvalEnvironment {
        let scope = env.makeChild()
        let params = Array(decl.signature.parameterClause.parameters)
        let args = Array(call.arguments)
        for (index, param) in params.enumerated() where index < args.count {
            let name = (param.secondName ?? param.firstName).text
            if let value = eval(args[index].expression, env) { scope.define(name, value) }
        }
        return scope
    }

    /// Calls a value-returning user function: binds params, then evaluates its
    /// body (handling `let`, `if/else` with `return`, `return`, and a trailing
    /// expression as the implicit return).
    func callValueFunction(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> SwiftValue? {
        env.budget.enter()
        defer { env.budget.leave() }
        guard !env.budget.exceeded else { return nil }
        guard let body = decl.body else { return nil }
        return evalBlockValue(body.statements, bindParameters(decl, call, env))
    }

    func evalBlockValue(_ items: CodeBlockItemListSyntax, _ scope: EvalEnvironment) -> SwiftValue? {
        var last: SwiftValue?
        for item in items {
            let node = item.item
            if let decl = node.as(VariableDeclSyntax.self) {
                for binding in decl.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                       let value = binding.initializer.flatMap({ eval($0.value, scope) }) {
                        scope.define(name, value)
                    }
                }
                continue
            }
            if let ret = node.as(ReturnStmtSyntax.self) {
                return ret.expression.flatMap { eval($0, scope) }
            }
            if let ifExpr = node.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self) ?? node.as(IfExprSyntax.self) {
                if let value = evalIfValue(ifExpr, scope) { return value }
                continue
            }
            if let switchExpr = node.as(ExpressionStmtSyntax.self)?.expression.as(SwitchExprSyntax.self) ?? node.as(SwitchExprSyntax.self) {
                if let value = evalSwitchValue(switchExpr, scope) { return value }
                continue
            }
            if let expr = node.as(ExprSyntax.self) {
                if let ifExpr = expr.as(IfExprSyntax.self) {
                    if let value = evalIfValue(ifExpr, scope) { return value }
                    continue
                }
                if let switchExpr = expr.as(SwitchExprSyntax.self) {
                    if let value = evalSwitchValue(switchExpr, scope) { return value }
                    continue
                }
                last = eval(expr, scope)
            }
        }
        return last
    }

    private func evalIfValue(_ ifExpr: IfExprSyntax, _ scope: EvalEnvironment) -> SwiftValue? {
        let branchScope = scope.makeChild()
        if conditionsPass(ifExpr.conditions, branchScope) {
            return evalBlockValue(ifExpr.body.statements, branchScope)
        }
        guard let elseBody = ifExpr.elseBody else { return nil }
        if let block = elseBody.as(CodeBlockSyntax.self) {
            return evalBlockValue(block.statements, scope.makeChild())
        }
        if let elseIf = elseBody.as(IfExprSyntax.self) {
            return evalIfValue(elseIf, scope)
        }
        return nil
    }

    /// Evaluates an `if`/`guard` condition list, binding `if let` optionals into
    /// `scope`. Mirrors the view interpreter's version for value position.
    private func conditionsPass(_ conditions: ConditionElementListSyntax, _ scope: EvalEnvironment) -> Bool {
        for element in conditions {
            if let binding = element.condition.as(OptionalBindingConditionSyntax.self) {
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                let resolved: SwiftValue?
                if let initializer = binding.initializer?.value {
                    resolved = eval(initializer, scope)
                } else if let name {
                    resolved = scope.lookup(name)
                } else {
                    resolved = nil
                }
                guard let value = resolved else { return false }
                if let name { scope.define(name, value) }
            } else if let expr = element.condition.as(ExprSyntax.self) {
                if !(eval(expr, scope)?.isTruthy ?? false) { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Evaluates a value-position `switch`, returning the matching case's value.
    private func evalSwitchValue(_ switchExpr: SwitchExprSyntax, _ scope: EvalEnvironment) -> SwiftValue? {
        let subject = eval(switchExpr.subject, scope)
        for caseSyntax in switchExpr.cases {
            guard let switchCase = caseSyntax.as(SwitchCaseSyntax.self) else { continue }
            if switchCaseMatches(switchCase.label, subject, scope) {
                return evalBlockValue(switchCase.statements, scope.makeChild())
            }
        }
        return nil
    }

    /// Whether a `switch` case label matches `subject` (literal / bare `.member`
    /// patterns; `default` always matches).
    private func switchCaseMatches(_ label: SwitchCaseSyntax.Label, _ subject: SwiftValue?, _ scope: EvalEnvironment) -> Bool {
        switch label {
        case .default:
            return true
        case let .case(caseLabel):
            for item in caseLabel.caseItems {
                if let pattern = item.pattern.as(ExpressionPatternSyntax.self) {
                    if let member = pattern.expression.as(MemberAccessExprSyntax.self), member.base == nil,
                       case let .string(value)? = subject, member.declName.baseName.text == value {
                        return true
                    }
                    if eval(pattern.expression, scope) == subject { return true }
                }
            }
            return false
        }
    }

}
