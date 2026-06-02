import Foundation

/// Evaluates `LispValue` forms against an `LispEnvironment`.
///
/// One evaluator instance is used per render pass and is not shared across
/// threads. A step budget and recursion-depth guard bound the work a script can
/// do so a malformed `sidebar.lisp` can never wedge the main thread.
public final class Evaluator {
    public private(set) var steps = 0
    private var depth = 0

    public let stepLimit: Int
    public let depthLimit: Int

    // A sidebar row never legitimately recurses deep; this bound trips a runaway
    // script well before its Swift call stack (which uses several frames per Lisp
    // level) can overflow a small worker-thread stack.
    public init(stepLimit: Int = 2_000_000, depthLimit: Int = 64) {
        self.stepLimit = stepLimit
        self.depthLimit = depthLimit
    }

    public func eval(_ form: LispValue, in env: LispEnvironment) throws -> LispValue {
        steps += 1
        if steps > stepLimit { throw LispError.stepLimit }

        switch form {
        case .int, .double, .string, .bool, .null, .keyword, .function, .style, .node, .map:
            return form
        case .symbol(let name):
            guard let value = env.lookup(name) else { throw LispError.unbound(name) }
            return value
        case .list(let items):
            return try evalList(items, in: env)
        }
    }

    private func evalList(_ items: [LispValue], in env: LispEnvironment) throws -> LispValue {
        guard let head = items.first else { return .null } // () evaluates to nil

        // Special forms dispatch on a bare leading symbol.
        if case .symbol(let name) = head {
            if let result = try evalSpecialForm(name, Array(items.dropFirst()), in: env) {
                return result
            }
        }

        let fn = try eval(head, in: env)
        let args = try items.dropFirst().map { try eval($0, in: env) }
        return try apply(fn, Array(args))
    }

    /// Returns nil when `name` is not a special form (so it falls through to a
    /// normal function call).
    private func evalSpecialForm(_ name: String, _ args: [LispValue], in env: LispEnvironment) throws -> LispValue? {
        switch name {
        case "quote":
            return args.first ?? .null

        case "if":
            guard args.count == 2 || args.count == 3 else {
                throw LispError.arity("if", expected: "2 or 3 arguments", got: args.count)
            }
            if try eval(args[0], in: env).isTruthy {
                return try eval(args[1], in: env)
            } else if args.count == 3 {
                return try eval(args[2], in: env)
            }
            return .null

        case "when":
            guard let test = args.first else { return .null }
            if try eval(test, in: env).isTruthy {
                return try evalBody(Array(args.dropFirst()), in: env)
            }
            return .null

        case "unless":
            guard let test = args.first else { return .null }
            if try !eval(test, in: env).isTruthy {
                return try evalBody(Array(args.dropFirst()), in: env)
            }
            return .null

        case "cond":
            for clause in args {
                guard case .list(let parts) = clause, let test = parts.first else {
                    throw LispError.eval(String(localized: "sidebarScript.error.condClause",
                        defaultValue: "Each 'cond' clause must be a list.", bundle: .module))
                }
                let isElse = (test == .symbol("else")) || (test == .keyword("else"))
                if isElse {
                    return try evalBody(Array(parts.dropFirst()), in: env)
                }
                if try eval(test, in: env).isTruthy {
                    return try evalBody(Array(parts.dropFirst()), in: env)
                }
            }
            return .null

        case "and":
            var last: LispValue = .bool(true)
            for a in args {
                last = try eval(a, in: env)
                if !last.isTruthy { return last }
            }
            return last

        case "or":
            for a in args {
                let v = try eval(a, in: env)
                if v.isTruthy { return v }
            }
            return .null

        case "let", "let*":
            return try evalLet(args, in: env)

        case "def", "define":
            return try evalDef(args, in: env)

        case "set!":
            guard args.count == 2, case .symbol(let target) = args[0] else {
                throw LispError.eval(String(localized: "sidebarScript.error.setForm",
                    defaultValue: "'set!' needs a name and a value.", bundle: .module))
            }
            let value = try eval(args[1], in: env)
            if !env.set(target, value) { throw LispError.unbound(target) }
            return value

        case "fn", "lambda":
            return try makeClosure(args, in: env)

        case "do", "begin":
            return try evalBody(args, in: env)

        case "quasiquote", "unquote":
            // Not supported; keep the core small.
            return nil

        default:
            return nil
        }
    }

    private func evalBody(_ forms: [LispValue], in env: LispEnvironment) throws -> LispValue {
        var result: LispValue = .null
        for f in forms { result = try eval(f, in: env) }
        return result
    }

    private func evalLet(_ args: [LispValue], in env: LispEnvironment) throws -> LispValue {
        guard let bindingsForm = args.first, case .list(let bindings) = bindingsForm else {
            throw LispError.eval(String(localized: "sidebarScript.error.letBindings",
                defaultValue: "'let' needs a list of bindings.", bundle: .module))
        }
        let scope = env.child()
        for binding in bindings {
            guard case .list(let pair) = binding, pair.count == 2,
                  case .symbol(let name) = pair[0] else {
                throw LispError.eval(String(localized: "sidebarScript.error.letBindingShape",
                    defaultValue: "Each 'let' binding must be (name value).", bundle: .module))
            }
            // Sequential binding (let*): later bindings see earlier ones.
            scope.define(name, try eval(pair[1], in: scope))
        }
        return try evalBody(Array(args.dropFirst()), in: scope)
    }

    private func evalDef(_ args: [LispValue], in env: LispEnvironment) throws -> LispValue {
        guard let target = args.first else {
            throw LispError.arity("def", expected: "a name", got: 0)
        }
        switch target {
        case .symbol(let name):
            let value = args.count > 1 ? try eval(args[1], in: env) : .null
            env.define(name, value)
            return value
        case .list(let sig):
            // (def (name params...) body...) function sugar.
            guard case .symbol(let name)? = sig.first else {
                throw LispError.eval(String(localized: "sidebarScript.error.defShape",
                    defaultValue: "Function definition needs a name.", bundle: .module))
            }
            let (params, rest) = try parseParams(Array(sig.dropFirst()))
            let closure = LispValue.function(LispFunction(
                name: name,
                kind: .closure(params: params, rest: rest, body: Array(args.dropFirst()), env: env)
            ))
            env.define(name, closure)
            return closure
        default:
            throw LispError.eval(String(localized: "sidebarScript.error.defShape",
                defaultValue: "Function definition needs a name.", bundle: .module))
        }
    }

    private func makeClosure(_ args: [LispValue], in env: LispEnvironment) throws -> LispValue {
        guard let paramsForm = args.first, case .list(let rawParams) = paramsForm else {
            throw LispError.eval(String(localized: "sidebarScript.error.fnParams",
                defaultValue: "'fn' needs a parameter list.", bundle: .module))
        }
        let (params, rest) = try parseParams(rawParams)
        return .function(LispFunction(
            name: "lambda",
            kind: .closure(params: params, rest: rest, body: Array(args.dropFirst()), env: env)
        ))
    }

    private func parseParams(_ forms: [LispValue]) throws -> (params: [String], rest: String?) {
        var params: [String] = []
        var rest: String?
        var i = 0
        while i < forms.count {
            guard case .symbol(let s) = forms[i] else {
                throw LispError.eval(String(localized: "sidebarScript.error.paramName",
                    defaultValue: "Parameter names must be symbols.", bundle: .module))
            }
            if s == "&" {
                guard i + 1 < forms.count, case .symbol(let r) = forms[i + 1] else {
                    throw LispError.eval(String(localized: "sidebarScript.error.restParam",
                        defaultValue: "'&' must be followed by one rest parameter.", bundle: .module))
                }
                rest = r
                break
            }
            params.append(s)
            i += 1
        }
        return (params, rest)
    }

    // MARK: - Application

    public func apply(_ fn: LispValue, _ args: [LispValue]) throws -> LispValue {
        guard case .function(let function) = fn else {
            throw LispError.notCallable(fn)
        }
        switch function.kind {
        case .builtin(let body):
            return try body(args, self)
        case .special:
            throw LispError.eval(String(localized: "sidebarScript.error.specialApplied",
                defaultValue: "'\(function.name)' cannot be used as a value.", bundle: .module))
        case let .closure(params, rest, body, closureEnv):
            return try applyClosure(function.name, params, rest, body, closureEnv, args)
        }
    }

    private func applyClosure(
        _ name: String,
        _ params: [String],
        _ rest: String?,
        _ body: [LispValue],
        _ closureEnv: LispEnvironment,
        _ args: [LispValue]
    ) throws -> LispValue {
        depth += 1
        defer { depth -= 1 }
        if depth > depthLimit { throw LispError.depthLimit }

        if rest == nil && args.count != params.count {
            throw LispError.arity(name, expected: "\(params.count) arguments", got: args.count)
        }
        if rest != nil && args.count < params.count {
            throw LispError.arity(name, expected: "at least \(params.count) arguments", got: args.count)
        }
        let scope = closureEnv.child()
        for (i, p) in params.enumerated() {
            scope.define(p, args[i])
        }
        if let rest {
            scope.define(rest, .list(Array(args.dropFirst(params.count))))
        }
        return try evalBody(body, in: scope)
    }
}
