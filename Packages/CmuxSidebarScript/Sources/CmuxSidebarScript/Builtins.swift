import Foundation

/// Installs the core, SwiftUI-agnostic standard library into an environment.
enum Builtins {
    static func install(into env: LispEnvironment) {
        func def(_ name: String, _ body: @escaping (_ args: [LispValue], _ ev: Evaluator) throws -> LispValue) {
            env.define(name, .function(LispFunction(name: name, kind: .builtin(body))))
        }

        // MARK: Arithmetic
        def("+") { args, _ in try .number(args.reduce(0) { $0 + (try num($1, "+")) }) }
        def("*") { args, _ in try .number(args.reduce(1) { $0 * (try num($1, "*")) }) }
        def("-") { args, _ in
            guard let head = args.first else { return .int(0) }
            if args.count == 1 { return .number(-(try num(head, "-"))) }
            return try .number(args.dropFirst().reduce(num(head, "-")) { $0 - (try num($1, "-")) })
        }
        def("/") { args, _ in
            guard let head = args.first else { throw LispError.arity("/", expected: "≥1 argument", got: 0) }
            if args.count == 1 { return try .number(1 / num(head, "/")) }
            return try .number(args.dropFirst().reduce(num(head, "/")) { $0 / (try num($1, "/")) })
        }
        def("mod") { args, _ in
            try pair("mod", args); let a = try num(args[0], "mod"), b = try num(args[1], "mod")
            return .number(a.truncatingRemainder(dividingBy: b))
        }
        def("abs") { args, _ in try .number(abs(num(one(args, "abs"), "abs"))) }
        def("floor") { args, _ in try .number(num(one(args, "floor"), "floor").rounded(.down)) }
        def("ceil") { args, _ in try .number(num(one(args, "ceil"), "ceil").rounded(.up)) }
        def("round") { args, _ in try .number(num(one(args, "round"), "round").rounded()) }
        def("min") { args, _ in try .number(args.map { try num($0, "min") }.min() ?? 0) }
        def("max") { args, _ in try .number(args.map { try num($0, "max") }.max() ?? 0) }

        // MARK: Comparison & logic
        def("=") { args, _ in .bool(allAdjacent(args) { $0 == $1 }) }
        def("not=") { args, _ in .bool(!allAdjacent(args) { $0 == $1 }) }
        def("<") { args, _ in try .bool(numCompare(args, "<") { $0 < $1 }) }
        def(">") { args, _ in try .bool(numCompare(args, ">") { $0 > $1 }) }
        def("<=") { args, _ in try .bool(numCompare(args, "<=") { $0 <= $1 }) }
        def(">=") { args, _ in try .bool(numCompare(args, ">=") { $0 >= $1 }) }
        def("not") { args, _ in .bool(!one(args, "not").isTruthy) }

        // MARK: Type predicates
        def("nil?") { args, _ in .bool({ if case .null = one(args, "nil?") { return true }; return false }()) }
        def("number?") { args, _ in .bool(one(args, "number?").asDouble != nil) }
        def("string?") { args, _ in .bool({ if case .string = one(args, "string?") { return true }; return false }()) }
        def("list?") { args, _ in .bool({ if case .list = one(args, "list?") { return true }; return false }()) }
        def("bool?") { args, _ in .bool({ if case .bool = one(args, "bool?") { return true }; return false }()) }
        def("node?") { args, _ in .bool({ if case .node = one(args, "node?") { return true }; return false }()) }
        def("empty?") { args, _ in
            switch one(args, "empty?") {
            case .null: return .bool(true)
            case .list(let l): return .bool(l.isEmpty)
            case .string(let s): return .bool(s.isEmpty)
            default: return .bool(false)
            }
        }

        // MARK: Lists
        def("list") { args, _ in .list(args) }
        def("cons") { args, _ in
            try pair("cons", args)
            if case .list(let rest) = args[1] { return .list([args[0]] + rest) }
            return .list([args[0], args[1]])
        }
        def("first") { args, _ in (try listArg(one(args, "first"), "first")).first ?? .null }
        def("last") { args, _ in (try listArg(one(args, "last"), "last")).last ?? .null }
        def("rest") { args, _ in .list(Array((try listArg(one(args, "rest"), "rest")).dropFirst())) }
        def("count") { args, _ in
            switch one(args, "count") {
            case .list(let l): return .int(l.count)
            case .string(let s): return .int(s.count)
            case .null: return .int(0)
            case .map(let m): return .int(m.keys.count)
            default: return .int(0)
            }
        }
        def("nth") { args, _ in
            try pair("nth", args)
            let list = try listArg(args[0], "nth")
            let i = Int(try num(args[1], "nth"))
            return (i >= 0 && i < list.count) ? list[i] : (args.count > 2 ? args[2] : .null)
        }
        def("reverse") { args, _ in .list((try listArg(one(args, "reverse"), "reverse")).reversed()) }
        def("append") { args, _ in
            var out: [LispValue] = []
            for a in args { out.append(contentsOf: try listArg(a, "append")) }
            return .list(out)
        }
        def("contains?") { args, _ in
            try pair("contains?", args)
            return .bool((try listArg(args[0], "contains?")).contains(args[1]))
        }
        def("range") { args, _ in try rangeBuiltin(args) }

        // MARK: Higher-order
        def("map") { args, ev in
            try pair("map", args)
            let fn = args[0]
            return .list(try listArg(args[1], "map").map { try ev.apply(fn, [$0]) })
        }
        def("map-indexed") { args, ev in
            try pair("map-indexed", args)
            let fn = args[0]
            return .list(try listArg(args[1], "map-indexed").enumerated().map {
                try ev.apply(fn, [.int($0.offset), $0.element])
            })
        }
        def("filter") { args, ev in
            try pair("filter", args)
            let fn = args[0]
            return .list(try listArg(args[1], "filter").filter { try ev.apply(fn, [$0]).isTruthy })
        }
        def("reduce") { args, ev in
            guard args.count == 3 else { throw LispError.arity("reduce", expected: "3 arguments", got: args.count) }
            let fn = args[0]
            var acc = args[1]
            for item in try listArg(args[2], "reduce") { acc = try ev.apply(fn, [acc, item]) }
            return acc
        }
        def("for-each") { args, ev in
            try pair("for-each", args)
            let fn = args[0]
            for item in try listArg(args[1], "for-each") { _ = try ev.apply(fn, [item]) }
            return .null
        }

        // MARK: Strings
        def("str") { args, _ in .string(args.map { display($0) }.joined()) }
        def("join") { args, _ in
            try pair("join", args)
            let sep = try str(args[0], "join")
            return .string((try listArg(args[1], "join")).map { display($0) }.joined(separator: sep))
        }
        def("split") { args, _ in
            try pair("split", args)
            let s = try str(args[0], "split"), sep = try str(args[1], "split")
            let parts = sep.isEmpty ? s.map { String($0) } : s.components(separatedBy: sep)
            return .list(parts.map { .string($0) })
        }
        def("upper") { args, _ in .string((try str(one(args, "upper"), "upper")).uppercased()) }
        def("lower") { args, _ in .string((try str(one(args, "lower"), "lower")).lowercased()) }
        def("trim") { args, _ in .string((try str(one(args, "trim"), "trim")).trimmingCharacters(in: .whitespacesAndNewlines)) }
        def("string-length") { args, _ in .int((try str(one(args, "string-length"), "string-length")).count) }
        def("starts-with?") { args, _ in
            try pair("starts-with?", args)
            return .bool((try str(args[0], "starts-with?")).hasPrefix(try str(args[1], "starts-with?")))
        }
        def("ends-with?") { args, _ in
            try pair("ends-with?", args)
            return .bool((try str(args[0], "ends-with?")).hasSuffix(try str(args[1], "ends-with?")))
        }
        def("includes?") { args, _ in
            try pair("includes?", args)
            return .bool((try str(args[0], "includes?")).contains(try str(args[1], "includes?")))
        }
        def("substring") { args, _ in try substringBuiltin(args) }
        def("replace") { args, _ in
            guard args.count == 3 else { throw LispError.arity("replace", expected: "3 arguments", got: args.count) }
            let s = try str(args[0], "replace")
            return .string(s.replacingOccurrences(of: try str(args[1], "replace"), with: try str(args[2], "replace")))
        }
        def("pad-left") { args, _ in try pad(args, left: true) }
        def("pad-right") { args, _ in try pad(args, left: false) }

        // MARK: Records (maps)
        def("record") { args, _ in
            var m = LispMap()
            var i = 0
            while i + 1 < args.count {
                guard case .keyword(let k) = args[i] else {
                    throw LispError.eval(String(localized: "sidebarScript.error.recordKey",
                        defaultValue: "'record' keys must be :keywords.", bundle: .module))
                }
                m[k] = args[i + 1]
                i += 2
            }
            return .map(m)
        }
        def("get") { args, _ in try getBuiltin(args) }
        def("has?") { args, _ in
            try pair("has?", args)
            if case .map(let m) = args[0] { return .bool(m[keyName(args[1])] != nil) }
            return .bool(false)
        }
        def("keys") { args, _ in
            if case .map(let m) = one(args, "keys") { return .list(m.keys.map { .keyword($0) }) }
            return .list([])
        }
        def("assoc") { args, _ in
            guard args.count >= 3, case .map(var m) = args[0] else {
                throw LispError.type("assoc", expected: "a record", got: args.first ?? .null)
            }
            var i = 1
            while i + 1 < args.count {
                m[keyName(args[i])] = args[i + 1]
                i += 2
            }
            return .map(m)
        }

        def("identity") { args, _ in one(args, "identity") }
    }

    // MARK: - Helpers

    private static func num(_ v: LispValue, _ form: String) throws -> Double {
        guard let d = v.asDouble else { throw LispError.type(form, expected: "a number", got: v) }
        return d
    }
    private static func str(_ v: LispValue, _ form: String) throws -> String {
        if case .string(let s) = v { return s }
        throw LispError.type(form, expected: "a string", got: v)
    }
    private static func one(_ args: [LispValue], _ form: String) -> LispValue { args.first ?? .null }
    private static func pair(_ form: String, _ args: [LispValue]) throws {
        guard args.count >= 2 else { throw LispError.arity(form, expected: "2 arguments", got: args.count) }
    }
    private static func listArg(_ v: LispValue, _ form: String) throws -> [LispValue] {
        switch v {
        case .list(let l): return l
        case .null: return []
        default: throw LispError.type(form, expected: "a list", got: v)
        }
    }
    private static func keyName(_ v: LispValue) -> String {
        switch v {
        case .keyword(let k), .string(let k), .symbol(let k): return k
        default: return display(v)
        }
    }

    private static func allAdjacent(_ args: [LispValue], _ ok: (LispValue, LispValue) -> Bool) -> Bool {
        guard args.count >= 2 else { return true }
        for i in 1..<args.count where !ok(args[i - 1], args[i]) { return false }
        return true
    }
    private static func numCompare(_ args: [LispValue], _ form: String, _ ok: (Double, Double) -> Bool) throws -> Bool {
        guard args.count >= 2 else { return true }
        for i in 1..<args.count where !(ok(try num(args[i - 1], form), try num(args[i], form))) { return false }
        return true
    }

    private static func rangeBuiltin(_ args: [LispValue]) throws -> LispValue {
        let nums = try args.map { try num($0, "range") }
        let start: Double, end: Double, step: Double
        switch nums.count {
        case 1: start = 0; end = nums[0]; step = 1
        case 2: start = nums[0]; end = nums[1]; step = 1
        case 3: start = nums[0]; end = nums[1]; step = nums[2]
        default: throw LispError.arity("range", expected: "1 to 3 arguments", got: args.count)
        }
        guard step != 0 else { return .list([]) }
        var out: [LispValue] = []
        var x = start
        if step > 0 { while x < end { out.append(.int(Int(x))); x += step } }
        else { while x > end { out.append(.int(Int(x))); x += step } }
        return .list(out)
    }

    private static func substringBuiltin(_ args: [LispValue]) throws -> LispValue {
        guard args.count >= 2 else { throw LispError.arity("substring", expected: "2 or 3 arguments", got: args.count) }
        let s = Array(try str(args[0], "substring"))
        let from = max(0, min(s.count, Int(try num(args[1], "substring"))))
        let to = args.count > 2 ? max(from, min(s.count, Int(try num(args[2], "substring")))) : s.count
        return .string(String(s[from..<to]))
    }

    private static func getBuiltin(_ args: [LispValue]) throws -> LispValue {
        guard args.count >= 2 else { throw LispError.arity("get", expected: "2 or 3 arguments", got: args.count) }
        let fallback: LispValue = args.count > 2 ? args[2] : .null
        switch args[0] {
        case .map(let m): return m[keyName(args[1])] ?? fallback
        case .list(let l):
            let i = Int((try? num(args[1], "get")) ?? -1)
            return (i >= 0 && i < l.count) ? l[i] : fallback
        case .null: return fallback
        default: return fallback
        }
    }

    private static func pad(_ args: [LispValue], left: Bool) throws -> LispValue {
        guard args.count >= 2 else { throw LispError.arity("pad", expected: "2 or 3 arguments", got: args.count) }
        let s = display(args[0])
        let width = Int(try num(args[1], "pad"))
        let padChar = args.count > 2 ? display(args[2]).first ?? " " : " "
        if s.count >= width { return .string(s) }
        let padding = String(repeating: padChar, count: width - s.count)
        return .string(left ? padding + s : s + padding)
    }

    /// Human-readable rendering for `str`/`join`. Integers print without a
    /// trailing `.0`; nil prints empty.
    static func display(_ v: LispValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .string(let s): return s
        case .symbol(let s): return s
        case .keyword(let k): return ":" + k
        case .list(let l): return "(" + l.map { display($0) }.joined(separator: " ") + ")"
        case .map(let m): return "{" + m.pairs.map { ":\($0.0) \(display($0.1))" }.joined(separator: " ") + "}"
        case .function(let f): return "#<fn \(f.name)>"
        case .style: return "#<style>"
        case .node(let n): return "#<view \(n.kind)>"
        }
    }
}
