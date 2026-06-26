/// Decoding helpers shared by the notification-policy merge-patch structs.
///
/// Hook patches distinguish "key absent" (leave the field untouched) from "key
/// present and null" (explicitly clear an optional field). These two helpers
/// encode that distinction so each patch can decode `T?` versus `T??` precisely.
extension KeyedDecodingContainer {
    /// Decodes a value only when the key is present, returning `nil` when the
    /// key is absent (so a missing key never overwrites the merge target).
    func decodeIfNonNullValuePresent<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    /// Decodes a nullable value only when the key is present, distinguishing an
    /// absent key (`nil`) from a present-but-null value (`.some(nil)`).
    func decodeNullableValueIfPresent<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T?? {
        guard contains(key) else { return nil }
        return try decode(T?.self, forKey: key)
    }
}
