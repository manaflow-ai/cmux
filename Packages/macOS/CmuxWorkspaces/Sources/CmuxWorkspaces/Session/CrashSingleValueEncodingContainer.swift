/// Counts scalars and delegates compound single values back to bounded traversal.
struct CrashSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: CrashCountingEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    mutating func encodeNil() throws { try encoder.budget.charge(bytes: 4, nodes: 1) }
    mutating func encode(_ value: Bool) throws { try encoder.budget.charge(bytes: value ? 4 : 5, nodes: 1) }
    mutating func encode(_ value: String) throws { try encoder.budget.string(value) }
    mutating func encode(_ value: Double) throws {
        guard value.isFinite else { throw CrashEncodingBudget.Failure.invalidValue }
        try encoder.budget.charge(bytes: 32, nodes: 1)
    }
    mutating func encode(_ value: Float) throws {
        guard value.isFinite else { throw CrashEncodingBudget.Failure.invalidValue }
        try encoder.budget.charge(bytes: 32, nodes: 1)
    }
    mutating func encode(_ value: Int) throws { try encoder.budget.charge(bytes: 21, nodes: 1) }
    mutating func encode(_ value: Int8) throws { try encoder.budget.charge(bytes: 4, nodes: 1) }
    mutating func encode(_ value: Int16) throws { try encoder.budget.charge(bytes: 6, nodes: 1) }
    mutating func encode(_ value: Int32) throws { try encoder.budget.charge(bytes: 11, nodes: 1) }
    mutating func encode(_ value: Int64) throws { try encoder.budget.charge(bytes: 21, nodes: 1) }
    mutating func encode(_ value: UInt) throws { try encoder.budget.charge(bytes: 20, nodes: 1) }
    mutating func encode(_ value: UInt8) throws { try encoder.budget.charge(bytes: 3, nodes: 1) }
    mutating func encode(_ value: UInt16) throws { try encoder.budget.charge(bytes: 5, nodes: 1) }
    mutating func encode(_ value: UInt32) throws { try encoder.budget.charge(bytes: 10, nodes: 1) }
    mutating func encode(_ value: UInt64) throws { try encoder.budget.charge(bytes: 20, nodes: 1) }
    mutating func encode<Value: Encodable>(_ value: Value) throws {
        try encoder.child(CrashEncodingKey(stringValue: "value")).encode(value)
    }
}
