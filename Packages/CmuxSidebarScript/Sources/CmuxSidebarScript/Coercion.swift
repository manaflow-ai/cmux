import Foundation

/// Splits a flat evaluated argument list into positional args and `:keyword`
/// options. A keyword consumes exactly the next value, so positionals and
/// options can interleave freely: `(vstack :spacing 4 child1 child2)` and
/// `(vstack child1 child2 :spacing 4)` mean the same thing.
struct SplitArgs {
    var positional: [LispValue]
    /// Keyword options in source order (a keyword may repeat, last wins on read).
    var options: [(String, LispValue)]

    func option(_ key: String) -> LispValue? {
        options.last(where: { $0.0 == key })?.1
    }
}

enum Coercion {
    static func split(_ args: [LispValue], formName: String) throws -> SplitArgs {
        var positional: [LispValue] = []
        var options: [(String, LispValue)] = []
        var i = 0
        while i < args.count {
            if case .keyword(let key) = args[i] {
                guard i + 1 < args.count else {
                    throw LispError.eval(String(
                        localized: "sidebarScript.error.danglingKeyword",
                        defaultValue: "':\(key)' in '\(formName)' is missing a value.",
                        bundle: .module))
                }
                options.append((key, args[i + 1]))
                i += 2
            } else {
                positional.append(args[i])
                i += 1
            }
        }
        return SplitArgs(positional: positional, options: options)
    }

    /// Flattens children: a positional arg that is a list (or nil) is spliced in,
    /// so `(map ...)` returning a list of nodes works as container content. Only
    /// node-producing values become children; nil is dropped.
    static func childNodes(_ values: [LispValue], formName: String) throws -> [RenderNode] {
        var nodes: [RenderNode] = []
        for v in values {
            try collectNodes(v, into: &nodes, formName: formName)
        }
        return nodes
    }

    private static func collectNodes(_ v: LispValue, into nodes: inout [RenderNode], formName: String) throws {
        switch v {
        case .node(let n):
            nodes.append(n)
        case .null:
            break // skip; lets scripts use nil for "render nothing"
        case .list(let items):
            for item in items { try collectNodes(item, into: &nodes, formName: formName) }
        case .string(let s):
            // Convenience: a bare string in container content is plain text.
            nodes.append(RenderNode(kind: "text", content: ["text": .string(s)]))
        default:
            throw LispError.eval(String(
                localized: "sidebarScript.error.childType",
                defaultValue: "'\(formName)' can only contain views, but got a \(v.typeName).",
                bundle: .module))
        }
    }

    static func number(_ v: LispValue, _ form: String) throws -> Double {
        guard let d = v.asDouble else { throw LispError.type(form, expected: "a number", got: v) }
        return d
    }

    static func string(_ v: LispValue, _ form: String) throws -> String {
        if case .string(let s) = v { return s }
        throw LispError.type(form, expected: "a string", got: v)
    }

    /// Coerces a Lisp value into an `RNValue` for use in a modifier/content slot.
    /// Strings that look like hex colors are NOT auto-converted here; callers
    /// that want color coercion use `color(_:)`.
    static func rnValue(_ v: LispValue) throws -> RNValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .keyword(let k): return .string(k)
        case .symbol(let s): return .string(s)
        case .node(let n): return .node(n)
        case .list(let items): return .list(try items.map { try rnValue($0) })
        case .style(let style): return style.rnValue
        case .map, .function:
            throw LispError.eval(String(
                localized: "sidebarScript.error.notRenderable",
                defaultValue: "A \(v.typeName) cannot be used here.", bundle: .module))
        }
    }

    /// Coerces a value into a color: accepts a style color, a `#hex` string, or a
    /// color-name keyword/symbol like `red` / `:accent`.
    static func color(_ v: LispValue, _ form: String) throws -> RNColor {
        switch v {
        case .style(.color(let c)): return c
        case .string(let s): return parseColorString(s)
        case .keyword(let k), .symbol(let k): return colorFromName(k)
        default:
            throw LispError.type(form, expected: "a color", got: v)
        }
    }

    static func parseColorString(_ s: String) -> RNColor {
        if s.hasPrefix("#") { return .hex(s) }
        return colorFromName(s)
    }

    static func colorFromName(_ name: String) -> RNColor {
        switch name {
        case "primary", "secondary", "accent", "clear", "label", "tint":
            return .semantic(name)
        default:
            return .named(name)
        }
    }

    /// Coerces a value into an alignment token.
    static func alignment(_ v: LispValue, _ form: String) throws -> RNAlignment {
        switch v {
        case .style(.alignment(let a)): return a
        case .keyword(let k), .symbol(let k), .string(let k): return RNAlignment(k)
        default:
            throw LispError.type(form, expected: "an alignment", got: v)
        }
    }

    /// Coerces a value into edge insets: a number (uniform) or an edges style.
    static func edges(_ v: LispValue, _ form: String) throws -> RNEdges {
        if let d = v.asDouble { return .uniform(d) }
        if case .style(.edges(let e)) = v { return e }
        throw LispError.type(form, expected: "a number or edges", got: v)
    }
}
