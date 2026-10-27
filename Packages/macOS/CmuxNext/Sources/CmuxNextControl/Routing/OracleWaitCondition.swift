#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import CmuxNextSettings
import Foundation

/// What `debug.oracle.wait_for` waits for: the snapshot value at a JSON pointer (RFC 6901) that starts
/// with a facet name meets `equals` or a `predicate` (schemas/oracle/case-v1.schema.json, `$defs/waitFor`).
/// Pure: parsed once from the request, evaluated against each facet value the wait reads.
///
/// `changed` compares with `since`, the value at the pointer the runner read at the step's `before`
/// checkpoint (null: absent), never with the wait's own first read: an action applies its intent in the input's
/// turn, so by the time the wait reads, the value usually changed already. `changed` without `since`, and
/// `since` with any other test, are `invalid_params`.
struct OracleWaitCondition: Sendable, Hashable {
    enum Test: Sendable, Hashable {
        case equals(JSONValue)
        case exists
        case absent
        case empty
        case nonEmpty
        /// The value differs from `since`, the value before the step (null: absent).
        case changed(since: JSONValue)
        case compare(Comparison, JSONValue)
    }

    enum Comparison: String, Sendable, Hashable {
        case gt, gte, lt, lte, contains, lengthEquals
    }

    let facet: OracleFacet
    /// The pointer's tokens after the facet name, unescaped (`~1` is `/`, `~0` is `~`).
    let path: [String]
    let test: Test
    /// The bound of the wait: `maxMs` (1 to 30,000).
    let limit: Duration

    static let maxMilliseconds = 30_000

    init(facet: OracleFacet, path: [String], test: Test, limit: Duration) {
        self.facet = facet
        self.path = path
        self.test = test
        self.limit = limit
    }

    /// The condition of `debug.oracle.wait_for`'s params `{pointer, equals | predicate, maxMs}`.
    init(params: [String: JSONValue]) throws(OracleWaitConditionError) {
        guard let pointer = params["pointer"]?.stringValue else { throw .pointer("pointer must be a JSON pointer string") }
        let parsed = try Self.parse(pointer: pointer)
        facet = parsed.facet
        path = parsed.path
        guard let milliseconds = params["maxMs"]?.intValue, (1...Self.maxMilliseconds).contains(milliseconds) else {
            throw .maxMs
        }
        limit = .milliseconds(milliseconds)
        switch (params["equals"], params["predicate"]) {
        case (let value?, nil): test = .equals(value)
        case (nil, let predicate?): test = try Self.parse(predicate: predicate, since: params["since"])
        default: throw .test
        }
        if case .changed = test {} else if params["since"] != nil { throw .since }
    }

    static func parse(pointer: String) throws(OracleWaitConditionError) -> (facet: OracleFacet, path: [String]) {
        guard pointer.hasPrefix("/") else { throw .pointer("pointer must start with /<facet>") }
        var tokens: [String] = []
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            // RFC 6901 section 4: `~1` before `~0`, and no other `~` escape.
            let unescaped = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if raw.replacingOccurrences(of: "~0", with: "").replacingOccurrences(of: "~1", with: "").contains("~") {
                throw .pointer("pointer token \(raw) has a ~ that is not ~0 or ~1")
            }
            tokens.append(unescaped)
        }
        guard let first = tokens.first, let facet = OracleFacet(rawValue: first) else {
            throw .pointer("pointer must start with a facet name: \(pointer)")
        }
        return (facet, Array(tokens.dropFirst()))
    }

    static func parse(predicate: JSONValue, since: JSONValue?) throws(OracleWaitConditionError) -> Test {
        switch predicate {
        case .string("exists"): return .exists
        case .string("absent"): return .absent
        case .string("empty"): return .empty
        case .string("nonEmpty"): return .nonEmpty
        case .string("changed"):
            guard let since else { throw .since }
            return .changed(since: since)
        case .object(let members):
            guard members.count == 2, let op = members["op"]?.stringValue.flatMap(Comparison.init(rawValue:)),
                  let value = members["value"] else { throw .test }
            return .compare(op, value)
        default: throw .test
        }
    }

    /// The value at the pointer inside `facetValue` (the facet's own value), nil when a step is missing.
    func value(in facetValue: JSONValue) -> JSONValue? {
        var current = facetValue
        for token in path {
            switch current {
            case .object:
                guard let next = current[token] else { return nil }
                current = next
            case .array(let items):
                // RFC 6901: a decimal index without a leading zero.
                guard let index = Int(token), String(index) == token, index >= 0, let next = items.dropFirst(index).first else { return nil }
                current = next
            default:
                return nil
            }
        }
        return current
    }

    /// Whether `value` (nil: the pointer resolves to nothing) meets the condition.
    func holds(_ value: JSONValue?) -> Bool {
        switch test {
        case .equals(let expected): return value == expected
        case .exists: return value != nil
        case .absent: return value == nil
        case .empty: return value.flatMap(Self.length) == 0
        case .nonEmpty: return value.flatMap(Self.length).map { $0 > 0 } ?? false
        // A runner reads an absent pointer as null: absent and null are the same baseline.
        case .changed(let since): return (value ?? .null) != since
        case .compare(let op, let operand):
            guard let value else { return false }
            return Self.meets(value, op, operand)
        }
    }

    private static func length(_ value: JSONValue) -> Int? {
        switch value {
        case .array(let items): items.count
        case .object(let members): members.count
        case .string(let text): text.count
        default: nil
        }
    }

    /// Facets carry decimals as strings (schemas/oracle/README.md): a numeric string compares as its number.
    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }

    private static func meets(_ value: JSONValue, _ op: Comparison, _ operand: JSONValue) -> Bool {
        switch op {
        case .gt, .gte, .lt, .lte:
            guard let left = number(value), let right = number(operand) else { return false }
            switch op {
            case .gt: return left > right
            case .gte: return left >= right
            case .lt: return left < right
            default: return left <= right
            }
        case .contains:
            switch value {
            case .array(let items): return items.contains(operand)
            case .string(let text): return operand.stringValue.map { text.contains($0) } ?? false
            case .object(let members): return operand.stringValue.map { members.keys.contains($0) } ?? false
            default: return false
            }
        case .lengthEquals:
            guard let expected = operand.intValue else { return false }
            return length(value) == expected
        }
    }
}

/// A `debug.oracle.wait_for` request the oracle cannot wait on (`invalid_params`).
enum OracleWaitConditionError: Error, Sendable, Hashable {
    case pointer(String)
    case maxMs
    /// `changed` without `since`, or `since` with another test.
    case since
    /// Neither or both of `equals` and `predicate`, or a predicate outside the schema's.
    case test

    var message: String {
        switch self {
        case .pointer(let reason): reason
        case .maxMs: "maxMs must be an integer from 1 to \(OracleWaitCondition.maxMilliseconds)"
        case .test: "give exactly one of equals or predicate (exists, absent, empty, nonEmpty, changed, or {op, value})"
        case .since: "since (the value at the pointer before the step; null: absent) goes with predicate changed, and only with it"
        }
    }

    var param: String {
        switch self {
        case .pointer: "pointer"
        case .maxMs: "maxMs"
        case .test: "predicate"
        case .since: "since"
        }
    }
}
#endif
