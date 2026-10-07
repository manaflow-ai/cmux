import CmuxMobileWire

extension JSONValue {
    /// The value at `key` decoded as `T`, or `TrustStoreEventError`.
    func require<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        guard let value = self[key], let decoded = try? value.decode(as: type) else { throw TrustStoreEventError(field: key) }
        return decoded
    }
}
