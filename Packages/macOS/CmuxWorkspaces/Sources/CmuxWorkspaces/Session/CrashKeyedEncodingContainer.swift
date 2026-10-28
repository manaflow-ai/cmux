/// Counts keyed container entries, including their escaped keys and separators.
struct CrashKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: CrashCountingEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil(forKey key: Key) throws {
        try prepare(key); try encoder.budget.charge(bytes: 4, nodes: 1)
    }
    mutating func encode<Value: Encodable>(_ value: Value, forKey key: Key) throws {
        try prepare(key); try encoder.child(key).encode(value)
    }
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        prepareWithoutThrowing(key)
        return encoder.child(key).container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        prepareWithoutThrowing(key)
        return encoder.child(key).unkeyedContainer()
    }
    mutating func superEncoder() -> any Encoder {
        let key = CrashEncodingKey(stringValue: "super")
        do { try encoder.budget.string(key.stringValue); try encoder.budget.charge(bytes: 2) }
        catch { encoder.budget.fail() }
        return encoder.child(key)
    }
    mutating func superEncoder(forKey key: Key) -> any Encoder {
        prepareWithoutThrowing(key); return encoder.child(key)
    }
    private func prepare(_ key: Key) throws {
        try encoder.budget.string(key.stringValue)
        try encoder.budget.charge(bytes: 2) // colon and conservative comma
    }
    private func prepareWithoutThrowing(_ key: Key) {
        do { try prepare(key) } catch { encoder.budget.fail() }
    }
}
