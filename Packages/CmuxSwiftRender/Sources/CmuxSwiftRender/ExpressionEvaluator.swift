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
        env.budget.enter()
        defer { env.budget.leave() }
        guard !env.budget.exceeded else { return nil }
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
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "Color" {
            return colorValue(call, env)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ["Array", "Int", "Double", "String"].contains(ref.baseName.text),
           env.lookupFunction(ref.baseName.text) == nil,
           let firstArg = call.arguments.first(where: { $0.label == nil })?.expression {
            let inner = eval(firstArg, env)
            switch ref.baseName.text {
            case "Array": return inner // `Array(seq)` / `Array(x.enumerated())`: identity.
            case "Int":
                switch inner {
                case let .int(i): return .int(i)
                // Int(_: Double) traps on NaN/infinity/overflow; authored
                // source can produce all three (e.g. `Int(1.0 / 0.0)`).
                case let .double(d): return Int(exactly: d.rounded(.towardZero)).map { .int($0) }
                case let .string(s): return Int(s).map { .int($0) }
                default: return nil
                }
            case "Double":
                switch inner {
                case let .double(d): return .double(d)
                case let .int(i): return .double(Double(i))
                case let .string(s): return Double(s).map { .double($0) }
                default: return nil
                }
            case "String":
                return inner.map { .string($0.displayString) }
            default: return nil
            }
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ["min", "max", "abs"].contains(ref.baseName.text),
           env.lookupFunction(ref.baseName.text) == nil {
            let nums = call.arguments.compactMap { numericValue(eval($0.expression, env)) }
            switch ref.baseName.text {
            case "min" where nums.count >= 2: return numberResult(nums.min()!, intIf: allInt(call, env))
            case "max" where nums.count >= 2: return numberResult(nums.max()!, intIf: allInt(call, env))
            case "abs" where nums.count == 1: return numberResult(Swift.abs(nums[0]), intIf: allInt(call, env))
            default: return nil
            }
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let decl = env.lookupFunction(ref.baseName.text) {
            return callValueFunction(decl, call, env)
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
        guard let lhs = eval(node.leftOperand, env) else { return nil }

        // Short-circuit logical operators on the left operand before forcing the
        // right one, so guard idioms like `i < items.count && items[i] == x`
        // don't evaluate (and fail on) the right side when the left is decisive.
        switch op {
        case "&&":
            guard lhs.isTruthy else { return .bool(false) }
            return .bool(eval(node.rightOperand, env)?.isTruthy ?? false)
        case "||":
            guard !lhs.isTruthy else { return .bool(true) }
            return .bool(eval(node.rightOperand, env)?.isTruthy ?? false)
        default:
            break
        }

        guard let rhs = eval(node.rightOperand, env) else { return nil }

        switch op {
        case "..<", "...":
            guard case let .int(l) = lhs, case let .int(r) = rhs else { return nil }
            return .range(lower: l, upper: r, inclusive: op == "...")
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
        case "/":
            // Interpreted user source supplies the divisor; a zero divisor must
            // return nil (caller skips) rather than trap the whole process.
            guard bothInt else { return .double(l / r) }
            let divisor = Int(r)
            guard divisor != 0 else { return nil }
            return .int(Int(l) / divisor)
        case "%":
            guard bothInt else { return nil }
            let divisor = Int(r)
            guard divisor != 0 else { return nil }
            return .int(Int(l) % divisor)
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
        case let .int(value):
            return numberMethod(Double(value), name, call)
        case let .double(value):
            return numberMethod(value, name, call)
        case let .array(values):
            switch name {
            case "filter":
                guard let closure else { return nil }
                return .array(values.filter { evalClosure(closure, $0, env)?.isTruthy ?? false })
            case "map":
                guard let closure else { return nil }
                return .array(values.compactMap { evalClosure(closure, $0, env) })
            case "flatMap":
                guard let closure else { return nil }
                var out: [SwiftValue] = []
                for v in values {
                    switch evalClosure(closure, v, env) {
                    case let .array(inner): out += inner
                    case let other?: out.append(other)
                    case nil: break
                    }
                }
                return .array(out)
            case "reduce":
                guard let closure, let initialExpr = call.arguments.first(where: { $0.label == nil })?.expression,
                      var acc = eval(initialExpr, env) else { return nil }
                for v in values {
                    if let next = evalClosure2(closure, acc, v, env) { acc = next }
                }
                return acc
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
            case "indices":
                return .array(values.indices.map { .int($0) })
            case "enumerated":
                // Each element is an index/value pair, addressable as
                // `.offset`/`.element` or destructured by a 2-arg closure
                // (`$0`/`$1`, stored under "0"/"1").
                return .array(values.enumerated().map { pair in
                    .object([
                        "offset": .int(pair.offset),
                        "element": pair.element,
                        "0": .int(pair.offset),
                        "1": pair.element,
                    ])
                })
            case "prefix":
                guard let firstArg, case let .int(n)? = eval(firstArg, env) else { return nil }
                return .array(Array(values.prefix(max(0, n))))
            case "dropFirst":
                let n = firstArg.flatMap { if case let .int(k)? = eval($0, env) { return k } else { return nil } } ?? 1
                return .array(Array(values.dropFirst(max(0, n))))
            case "dropLast":
                let n = firstArg.flatMap { if case let .int(k)? = eval($0, env) { return k } else { return nil } } ?? 1
                return .array(Array(values.dropLast(max(0, n))))
            case "suffix":
                guard let firstArg, case let .int(n)? = eval(firstArg, env) else { return nil }
                return .array(Array(values.suffix(max(0, n))))
            case "sorted":
                guard let closure else { return .array(sortedScalars(values)) }
                // Honor a 2-arg comparator like `sorted { $0.rank < $1.rank }`.
                // Use a stable insertion sort, not `Array.sorted(by:)`, because
                // an interpreted predicate isn't guaranteed to form a strict
                // weak ordering and `sorted(by:)` traps on those in debug.
                var result: [SwiftValue] = []
                for value in values {
                    var insertAt = result.count
                    for index in result.indices where evalClosure2(closure, value, result[index], env)?.isTruthy ?? false {
                        insertAt = index
                        break
                    }
                    result.insert(value, at: insertAt)
                }
                return .array(result)
            case "isEmpty":
                return .bool(values.isEmpty)
            case "joined":
                let separator: String = {
                    if let firstArg, case let .string(v)? = eval(firstArg, env) { return v }
                    return ""
                }()
                return .string(values.map { $0.displayString }.joined(separator: separator))
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
            case "capitalized": return .string(s.capitalized)
            case "isEmpty": return .bool(s.isEmpty)
            case "replacingOccurrences":
                func labeled(_ label: String) -> String? {
                    guard let e = call.arguments.first(where: { $0.label?.text == label })?.expression else { return nil }
                    if case let .string(v)? = eval(e, env) { return v }
                    return nil
                }
                guard let target = labeled("of"), let replacement = labeled("with") else { return nil }
                return .string(s.replacingOccurrences(of: target, with: replacement))
            case "split":
                guard let sep = argString(), let first = sep.first else { return nil }
                return .array(s.split(separator: first).map { .string(String($0)) })
            case "trimmingCharacters":
                // `.trimmingCharacters(in: .whitespaces / .whitespacesAndNewlines / .newlines)`
                let token = call.arguments.first(where: { $0.label?.text == "in" })?.expression.trimmedDescription ?? ""
                let set: CharacterSet = token.contains("newlines") && !token.contains("whitespacesAndNewlines")
                    ? .newlines
                    : (token.contains("whitespaces") ? (token.contains("AndNewlines") ? .whitespacesAndNewlines : .whitespaces) : .whitespacesAndNewlines)
                return .string(s.trimmingCharacters(in: set))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: - User functions (value-returning)

    /// Binds a call's arguments (by position) to a function's parameters in a
    /// fresh child scope, evaluating each argument in the caller's scope.
    func bindParameters(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax, _ env: Environment) -> Environment {
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
    private func callValueFunction(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax, _ env: Environment) -> SwiftValue? {
        env.budget.enter()
        defer { env.budget.leave() }
        guard !env.budget.exceeded else { return nil }
        guard let body = decl.body else { return nil }
        return evalBlockValue(body.statements, bindParameters(decl, call, env))
    }

    private func evalBlockValue(_ items: CodeBlockItemListSyntax, _ scope: Environment) -> SwiftValue? {
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

    private func evalIfValue(_ ifExpr: IfExprSyntax, _ scope: Environment) -> SwiftValue? {
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
    private func conditionsPass(_ conditions: ConditionElementListSyntax, _ scope: Environment) -> Bool {
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
    private func evalSwitchValue(_ switchExpr: SwitchExprSyntax, _ scope: Environment) -> SwiftValue? {
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
    private func switchCaseMatches(_ label: SwitchCaseSyntax.Label, _ subject: SwiftValue?, _ scope: Environment) -> Bool {
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

    /// The numeric reading of a value (int or double), else nil.
    private func numericValue(_ value: SwiftValue?) -> Double? {
        switch value {
        case let .int(i): return Double(i)
        case let .double(d): return d
        default: return nil
        }
    }

    /// Whether every argument of `call` evaluates to an integer (so a numeric
    /// builtin like `min` returns `.int`, not `.double`).
    private func allInt(_ call: FunctionCallExprSyntax, _ env: Environment) -> Bool {
        call.arguments.allSatisfy {
            if case .int? = eval($0.expression, env) { return true }
            return false
        }
    }

    /// Wraps a numeric result as `.int` when `intIf` is true, else `.double`.
    private func numberResult(_ value: Double, intIf: Bool) -> SwiftValue {
        intIf ? .int(Int(value)) : .double(value)
    }

    /// Returns the contents of the first double-quoted literal in `source`,
    /// e.g. the currency code in `.currency(code: "EUR")`.
    private func firstQuoted(in source: String) -> String? {
        guard let open = source.firstIndex(of: "\"") else { return nil }
        let afterOpen = source.index(after: open)
        guard let close = source[afterOpen...].firstIndex(of: "\"") else { return nil }
        return String(source[afterOpen..<close])
    }

    /// Number methods, chiefly `.formatted(...)`, honoring currency and
    /// compact-notation hints from the call's argument source.
    private func numberMethod(_ value: Double, _ name: String, _ call: FunctionCallExprSyntax) -> SwiftValue? {
        guard name == "formatted" else { return nil }
        let argSource = call.arguments.map { $0.expression.trimmedDescription }.joined(separator: " ")
        if argSource.contains("currency") {
            // Honor the `code:` argument (`.currency(code: "EUR")` -> "€…"),
            // not a hardcoded "$". Foundation resolves the symbol per code.
            let code = firstQuoted(in: argSource) ?? "USD"
            return .string(value.formatted(.currency(code: code)))
        }
        if argSource.contains("compact") || argSource.contains("notation") {
            let a = abs(value)
            if a >= 1_000_000 { return .string(String(format: "%.1fM", value / 1_000_000)) }
            if a >= 1_000 { return .string(String(format: "%.1fK", value / 1_000)) }
        }
        if argSource.contains("percent") { return .string(String(format: "%.0f%%", value * 100)) }
        return .string(value == value.rounded() ? String(Int(value)) : String(value))
    }

    /// Resolves `Color(...)` to a hex/token string usable by color modifiers:
    /// `Color("#hex")`, `Color(red:green:blue:)`, else nil.
    private func colorValue(_ call: FunctionCallExprSyntax, _ env: Environment) -> SwiftValue? {
        if let first = call.arguments.first(where: { $0.label == nil })?.expression,
           case let .string(token)? = eval(first, env) {
            return .string(token)
        }
        func channel(_ label: String) -> Int? {
            guard let e = call.arguments.first(where: { $0.label?.text == label })?.expression else { return nil }
            switch eval(e, env) {
            case let .double(d):
                // Clamp to [0,1] BEFORE converting — `Int(Double.infinity)` traps.
                guard d.isFinite else { return 0 }
                return max(0, min(255, Int((max(0, min(1, d)) * 255).rounded())))
            case let .int(i): return max(0, min(255, i))
            default: return nil
            }
        }
        if let r = channel("red"), let g = channel("green"), let b = channel("blue") {
            return .string(String(format: "#%02X%02X%02X", r, g, b))
        }
        return nil
    }

    /// Evaluates a two-parameter closure body with `a` bound to `$0` (and the
    /// first named param) and `b` bound to `$1` (and the second), for `reduce`.
    private func evalClosure2(_ closure: ClosureExprSyntax, _ a: SwiftValue, _ b: SwiftValue, _ env: Environment) -> SwiftValue? {
        let scope = env.makeChild()
        scope.define("$0", a)
        scope.define("$1", b)
        if case let .simpleInput(list)? = closure.signature?.parameterClause {
            let names = Array(list)
            if names.count > 0 { scope.define(names[0].name.text, a) }
            if names.count > 1 { scope.define(names[1].name.text, b) }
        }
        // Multi-statement bodies (local `let`, `if`/`switch`, trailing expr) are
        // evaluated like a value-func block, so `{ a, b in let s = a + b; s }`
        // works, not just single-expression closures.
        return evalBlockValue(closure.statements, scope)
    }

    /// Evaluates a closure body with `element` bound to the closure parameter
    /// (and `$0`), honoring local `let` bindings and a trailing expression.
    private func evalClosure(_ closure: ClosureExprSyntax, _ element: SwiftValue, _ env: Environment) -> SwiftValue? {
        let scope = env.makeChild()
        scope.define("$0", element)
        if let name = closureParameterName(closure) { scope.define(name, element) }
        return evalBlockValue(closure.statements, scope)
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
