import Foundation
import SwiftSyntax

/// Evaluates a (operator-folded) Swift expression to a ``SwiftValue``.
///
/// Supports literals, identifier lookup against an ``Environment``, string
/// interpolation, unary minus/not, and binary arithmetic, comparison,
/// logical, and range operators. Expressions it does not understand return
/// `nil` so the caller can skip them.
struct ExpressionEvaluator {
    func eval(_ expr: ExprSyntax, _ env: Environment) -> SwiftValue? {
        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return Int(literal.literal.text.replacingOccurrences(of: "_", with: "")).map(SwiftValue.int)
        }
        if let literal = expr.as(FloatLiteralExprSyntax.self) {
            return Double(literal.literal.text.replacingOccurrences(of: "_", with: "")).map(SwiftValue.double)
        }
        if let literal = expr.as(BooleanLiteralExprSyntax.self) {
            return .bool(literal.literal.text == "true")
        }
        if let literal = expr.as(StringLiteralExprSyntax.self) {
            return .string(evalString(literal, env))
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return env.lookup(ref.baseName.text)
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            return eval(base, env)?.member(member.declName.baseName.text)
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self),
           let indexExpr = subscriptCall.arguments.first?.expression {
            guard let base = eval(subscriptCall.calledExpression, env),
                  let index = eval(indexExpr, env) else { return nil }
            switch (base, index) {
            case let (.array(values), .int(i)):
                return (i >= 0 && i < values.count) ? values[i] : nil
            case let (.object(fields), .string(key)):
                return fields[key]
            default:
                return nil
            }
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            return eval(inner, env)
        }
        if let array = expr.as(ArrayExprSyntax.self) {
            let values = array.elements.compactMap { eval($0.expression, env) }
            return .array(values)
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            let taken = eval(ternary.condition, env)?.isTruthy ?? false
            return eval(taken ? ternary.thenExpression : ternary.elseExpression, env)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let baseExpr = member.base,
           let base = eval(baseExpr, env) {
            return evalMethod(base, member.declName.baseName.text, call, env)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            return evalPrefix(prefix.operator.text, eval(prefix.expression, env))
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return evalInfix(infix, env)
        }
        return nil
    }

    /// Evaluates a string literal, concatenating plain segments and
    /// interpolations evaluated against `env`.
    func evalString(_ literal: StringLiteralExprSyntax, _ env: Environment) -> String {
        var result = ""
        for segment in literal.segments {
            if let text = segment.as(StringSegmentSyntax.self) {
                result += text.content.text
            } else if let interp = segment.as(ExpressionSegmentSyntax.self),
                      let expr = interp.expressions.first?.expression {
                result += eval(expr, env)?.displayString ?? ""
            }
        }
        return result
    }

    // MARK: - Operators

    private func evalPrefix(_ op: String, _ value: SwiftValue?) -> SwiftValue? {
        switch (op, value) {
        case let ("-", .int(v)): return .int(-v)
        case let ("-", .double(v)): return .double(-v)
        case let ("!", .bool(v)): return .bool(!v)
        default: return nil
        }
    }

    private func evalInfix(_ node: InfixOperatorExprSyntax, _ env: Environment) -> SwiftValue? {
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text else { return nil }
        guard let lhs = eval(node.leftOperand, env), let rhs = eval(node.rightOperand, env) else { return nil }

        switch op {
        case "..<", "...":
            guard case let .int(l) = lhs, case let .int(r) = rhs else { return nil }
            return .range(lower: l, upper: r, inclusive: op == "...")
        case "&&": return .bool(lhs.isTruthy && rhs.isTruthy)
        case "||": return .bool(lhs.isTruthy || rhs.isTruthy)
        case "==": return .bool(lhs == rhs)
        case "!=": return .bool(lhs != rhs)
        default: break
        }

        // String concatenation
        if op == "+", case let .string(l) = lhs, case let .string(r) = rhs {
            return .string(l + r)
        }

        // Numeric arithmetic and comparison
        let (l, r, bothInt) = numericPair(lhs, rhs)
        guard let l, let r else { return nil }
        switch op {
        case "+": return bothInt ? .int(Int(l + r)) : .double(l + r)
        case "-": return bothInt ? .int(Int(l - r)) : .double(l - r)
        case "*": return bothInt ? .int(Int(l * r)) : .double(l * r)
        case "/": return bothInt ? .int(Int(l) / Int(r)) : .double(l / r)
        case "%": return bothInt ? .int(Int(l) % Int(r)) : nil
        case "<": return .bool(l < r)
        case ">": return .bool(l > r)
        case "<=": return .bool(l <= r)
        case ">=": return .bool(l >= r)
        default: return nil
        }
    }

    private func numericPair(_ lhs: SwiftValue, _ rhs: SwiftValue) -> (Double?, Double?, Bool) {
        func num(_ v: SwiftValue) -> (Double?, Bool) {
            switch v {
            case let .int(i): return (Double(i), true)
            case let .double(d): return (d, false)
            default: return (nil, false)
            }
        }
        let (l, lInt) = num(lhs)
        let (r, rInt) = num(rhs)
        return (l, r, lInt && rInt)
    }

    // MARK: - Value methods

    /// Evaluates a method call on a value: array higher-order methods and
    /// common string methods. Closures are single-expression and bound to
    /// `$0` (and any named parameter).
    private func evalMethod(_ base: SwiftValue, _ name: String, _ call: FunctionCallExprSyntax, _ env: Environment) -> SwiftValue? {
        let closure = call.trailingClosure
            ?? call.arguments.first(where: { ["where", "by"].contains($0.label?.text) })?.expression.as(ClosureExprSyntax.self)
        let firstArg = call.arguments.first(where: { $0.label == nil })?.expression
            ?? call.arguments.first?.expression

        switch base {
        case let .array(values):
            switch name {
            case "filter":
                guard let closure else { return nil }
                return .array(values.filter { evalClosure(closure, $0, env)?.isTruthy ?? false })
            case "map":
                guard let closure else { return nil }
                return .array(values.compactMap { evalClosure(closure, $0, env) })
            case "first":
                guard let closure else { return values.first }
                return values.first { evalClosure(closure, $0, env)?.isTruthy ?? false }
            case "contains":
                if let closure { return .bool(values.contains { evalClosure(closure, $0, env)?.isTruthy ?? false }) }
                guard let firstArg, let needle = eval(firstArg, env) else { return nil }
                return .bool(values.contains(needle))
            case "count":
                guard let closure else { return .int(values.count) }
                return .int(values.filter { evalClosure(closure, $0, env)?.isTruthy ?? false }.count)
            case "reversed":
                return .array(values.reversed())
            case "prefix":
                guard let firstArg, case let .int(n)? = eval(firstArg, env) else { return nil }
                return .array(Array(values.prefix(max(0, n))))
            case "sorted":
                return .array(sortedScalars(values))
            case "isEmpty":
                return .bool(values.isEmpty)
            default:
                return nil
            }
        case let .string(s):
            func argString() -> String? {
                guard let firstArg else { return nil }
                if case let .string(v)? = eval(firstArg, env) { return v }
                return nil
            }
            switch name {
            case "hasPrefix": return argString().map { .bool(s.hasPrefix($0)) }
            case "hasSuffix": return argString().map { .bool(s.hasSuffix($0)) }
            case "contains": return argString().map { .bool(s.contains($0)) }
            case "uppercased": return .string(s.uppercased())
            case "lowercased": return .string(s.lowercased())
            case "isEmpty": return .bool(s.isEmpty)
            case "split":
                guard let sep = argString(), let first = sep.first else { return nil }
                return .array(s.split(separator: first).map { .string(String($0)) })
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Evaluates a single-expression closure body with `element` bound to the
    /// closure parameter (and `$0`).
    private func evalClosure(_ closure: ClosureExprSyntax, _ element: SwiftValue, _ env: Environment) -> SwiftValue? {
        let scope = env.makeChild()
        scope.define("$0", element)
        if let name = closureParameterName(closure) { scope.define(name, element) }
        for item in closure.statements {
            if let expr = item.item.as(ExprSyntax.self) { return eval(expr, scope) }
        }
        return nil
    }

    private func closureParameterName(_ closure: ClosureExprSyntax) -> String? {
        guard let parameterClause = closure.signature?.parameterClause else { return nil }
        if case let .simpleInput(list) = parameterClause { return list.first?.name.text }
        if case let .parameterClause(clause) = parameterClause { return clause.parameters.first?.firstName.text }
        return nil
    }

    /// Sorts an array of scalar values (int/double/string) ascending; returns
    /// the input unchanged for non-scalar or mixed element types.
    private func sortedScalars(_ values: [SwiftValue]) -> [SwiftValue] {
        if values.allSatisfy({ if case .int = $0 { return true }; return false }) {
            return values.sorted { a, b in
                if case let .int(x) = a, case let .int(y) = b { return x < y }
                return false
            }
        }
        if values.allSatisfy({ if case .double = $0 { return true }; if case .int = $0 { return true }; return false }) {
            func d(_ v: SwiftValue) -> Double { if case let .int(i) = v { return Double(i) }; if case let .double(x) = v { return x }; return 0 }
            return values.sorted { d($0) < d($1) }
        }
        if values.allSatisfy({ if case .string = $0 { return true }; return false }) {
            return values.sorted { a, b in
                if case let .string(x) = a, case let .string(y) = b { return x < y }
                return false
            }
        }
        return values
    }
}
