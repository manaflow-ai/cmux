/// Counts array entries without retaining elements or their encodings.
struct CrashUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: CrashCountingEncoder
    var count = 0
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws {
        try prepare(); try encoder.budget.charge(bytes: 4, nodes: 1)
    }
    mutating func encode<Value: Encodable>(_ value: Value) throws {
        try prepare(); try encoder.child(CrashEncodingKey(index: count - 1)).encode(value)
    }
    mutating func nestedContainer<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        prepareWithoutThrowing()
        return encoder.child(CrashEncodingKey(index: count - 1)).container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        prepareWithoutThrowing()
        return encoder.child(CrashEncodingKey(index: count - 1)).unkeyedContainer()
    }
    mutating func superEncoder() -> any Encoder {
        prepareWithoutThrowing(); return encoder.child(CrashEncodingKey(index: count - 1))
    }
    private mutating func prepare() throws {
        try encoder.budget.charge(bytes: 1) // conservative comma, including first entry
        count += 1
    }
    private mutating func prepareWithoutThrowing() {
        do { try prepare() } catch { encoder.budget.fail() }
    }
}
