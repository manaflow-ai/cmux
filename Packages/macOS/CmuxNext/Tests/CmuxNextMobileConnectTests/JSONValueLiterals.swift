public import CmuxMobileWire

/// JSON literals in tests (the same retroactive conformances CmuxMobileHostTests uses).
extension JSONValue: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByBooleanLiteral,
    @retroactive ExpressibleByDictionaryLiteral, @retroactive ExpressibleByIntegerLiteral, @retroactive ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
