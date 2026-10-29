#if DEBUG || CMUX_BENCH_HOOKS
/// One facet value of an oracle snapshot, as JSON. The App converts it to the control socket's JSON once,
/// at the method's answer. Private text never goes in: a provider records it only as `sha256:<hex>`.
public enum OracleValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OracleValue])
    case object([String: OracleValue])

    public init(_ value: Int) { self = .number(Double(value)) }

    /// The schema's not-comparable form (`definitions.notComparable`): the build has no source for
    /// the facet, so the diff reports it and never passes it.
    public static func notComparable(reason: String, task: String) -> OracleValue {
        .object(["status": "not-comparable", "reason": .string(reason), "task": .string(task)])
    }

    public subscript(key: String) -> OracleValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }
}

extension OracleValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: OracleValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, OracleValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
#endif
