import Foundation

/// A runtime value produced while interpreting a Swift expression.
///
/// Phase 1 covers the value kinds needed for view logic: numbers, strings,
/// booleans, and ranges (the result of `0..<n`). The interpreter resolves
/// identifiers, string interpolations, loop sequences, and `if` conditions
/// to these.
public enum SwiftValue: Codable, Sendable, Equatable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case range(lower: Int, upper: Int, inclusive: Bool)
    indirect case array([SwiftValue])
    indirect case object([String: SwiftValue])

    /// How the value renders inside a string interpolation.
    public var displayString: String {
        switch self {
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .string(value): return value
        case let .bool(value): return String(value)
        case let .range(lower, upper, inclusive): return "\(lower)\(inclusive ? "..." : "..<")\(upper)"
        case let .array(values): return "[" + values.map(\.displayString).joined(separator: ", ") + "]"
        case let .object(fields): return "{" + fields.keys.sorted().map { "\($0): \(fields[$0]!.displayString)" }.joined(separator: ", ") + "}"
        }
    }

    /// Resolves a member (`value.name`): object fields, plus `count`/`isEmpty`
    /// on arrays and strings. Returns `nil` for unsupported members.
    public func member(_ name: String) -> SwiftValue? {
        switch self {
        case let .object(fields):
            return fields[name]
        case let .array(values):
            if name == "count" { return .int(values.count) }
            if name == "isEmpty" { return .bool(values.isEmpty) }
            if name == "indices" { return .array(values.indices.map { .int($0) }) }
            if name == "first" { return values.first }
            if name == "last" { return values.last }
            return nil
        case let .string(value):
            if name == "count" { return .int(value.count) }
            if name == "isEmpty" { return .bool(value.isEmpty) }
            if name == "capitalized" { return .string(value.capitalized) }
            if name == "uppercased" { return .string(value.uppercased()) }
            if name == "lowercased" { return .string(value.lowercased()) }
            return nil
        default:
            return nil
        }
    }

    /// The boolean reading of the value for `if` conditions.
    public var isTruthy: Bool {
        if case let .bool(value) = self { return value }
        return false
    }

    /// The values a `for` loop or `ForEach` iterates, for ranges and arrays.
    public var iterationValues: [SwiftValue]? {
        switch self {
        case let .range(lower, upper, inclusive):
            // Overflow-safe end + a materialization cap so a pathological range
            // (e.g. `0...Int.max`) can't overflow or exhaust memory.
            let (end, addOverflow) = inclusive ? upper.addingReportingOverflow(1) : (upper, false)
            guard !addOverflow, end >= lower else { return [] }
            let (count, subOverflow) = end.subtractingReportingOverflow(lower)
            guard !subOverflow, count <= 100_000 else { return [] }
            return (lower..<end).map(SwiftValue.int)
        case let .array(values):
            return values
        default:
            return nil
        }
    }
}
