/// A request field the catalog marks optional and nullable (`title` of `workspace.update`): the
/// daemon keeps the value when the field is absent, clears it on `null` and stores a value. A
/// Swift optional has only two of those three states, so a generated request spells such a field
/// as this type and the caller can still clear it (CmuxNextWireGen's ResourceEmitter, p05-ipc
/// task 045).
public enum ResourceFieldUpdate<Value: Sendable>: Sendable {
    /// Left out of the params: the daemon keeps what it has.
    case unchanged
    /// Sent as `null`: the daemon clears the field.
    case clear
    /// Sent as the value.
    case set(Value)

    /// Writes the field at `key`: nothing, `null` or the value.
    public func encode<Key: CodingKey>(into container: inout KeyedEncodingContainer<Key>,
                                       forKey key: Key) throws where Value: Encodable {
        switch self {
        case .unchanged: break
        case .clear: try container.encodeNil(forKey: key)
        case .set(let value): try container.encode(value, forKey: key)
        }
    }

    /// Reads the field at `key`: absent is `.unchanged`, `null` is `.clear`.
    public init<Key: CodingKey>(from container: KeyedDecodingContainer<Key>,
                                forKey key: Key) throws where Value: Decodable {
        if !container.contains(key) {
            self = .unchanged
        } else if try container.decodeNil(forKey: key) {
            self = .clear
        } else {
            self = .set(try container.decode(Value.self, forKey: key))
        }
    }
}

extension ResourceFieldUpdate: Equatable where Value: Equatable {}

extension ResourceFieldUpdate: Hashable where Value: Hashable {}
