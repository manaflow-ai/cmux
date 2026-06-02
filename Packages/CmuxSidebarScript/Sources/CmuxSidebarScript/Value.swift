import Foundation

/// A value in the sidebar Lisp.
///
/// The language is deliberately small: scalars, symbols, keywords, lists, and
/// functions, plus two host-bridge values (`style` and `node`) that let scripts
/// build SwiftUI render trees. Records (maps) carry structured host data such as
/// the workspace passed to `render-row`.
public indirect enum LispValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case symbol(String)
    /// A `:keyword`. Used for map keys and as lightweight enum tokens
    /// (alignments, weights, etc.).
    case keyword(String)
    case list([LispValue])
    /// An ordered record. Keys are bare strings (a `:title` key is stored as
    /// `"title"`). Used for the workspace passed to scripts and for any
    /// script-built record.
    case map(LispMap)
    case function(LispFunction)
    /// A resolved style value (color, font, gradient, ...). Consumed by view
    /// modifiers; never rendered on its own.
    case style(StyleValue)
    /// A built render node. The result of a view form.
    case node(RenderNode)
}

extension LispValue {
    /// Scheme-ish truthiness: only `false`, `nil`, and the empty list are falsy.
    /// Numbers (including 0) and strings (including "") are truthy so scripts can
    /// branch on the presence of optional data without surprises.
    public var isTruthy: Bool {
        switch self {
        case .bool(let b): return b
        case .null: return false
        case .list(let items): return !items.isEmpty
        default: return true
        }
    }

    public var typeName: String {
        switch self {
        case .null: return "nil"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .symbol: return "symbol"
        case .keyword: return "keyword"
        case .list: return "list"
        case .map: return "map"
        case .function: return "function"
        case .style: return "style"
        case .node: return "node"
        }
    }

    /// Numeric coercion for arithmetic and style params.
    public var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Builds a numeric value from a `Double`. Integral, finite magnitudes
    /// collapse to `.int` for clean display; everything else stays `.double`.
    public static func number(_ d: Double) -> LispValue {
        if d.isFinite, d == d.rounded(), abs(d) < 9e15 { return .int(Int(d)) }
        return .double(d)
    }
}

// MARK: - Equality (functions compare unequal; everything else is structural)

extension LispValue: Equatable {
    public static func == (lhs: LispValue, rhs: LispValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        case let (.string(a), .string(b)): return a == b
        case let (.symbol(a), .symbol(b)): return a == b
        case let (.keyword(a), .keyword(b)): return a == b
        case let (.list(a), .list(b)): return a == b
        case let (.map(a), .map(b)): return a == b
        case let (.style(a), .style(b)): return a == b
        case let (.node(a), .node(b)): return a == b
        case (.function, .function): return false
        default: return false
        }
    }
}
