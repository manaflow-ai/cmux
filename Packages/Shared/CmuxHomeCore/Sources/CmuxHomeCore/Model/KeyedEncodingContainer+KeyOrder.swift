import Foundation

extension KeyedEncodingContainer {
    /// Encodes an id-keyed dictionary the way `Dictionary` encodes a key that is not `String`, `Int`
    /// or `CodingKeyRepresentable` (one array of alternating keys and values), but in the keys'
    /// raw-value order instead of hash order.
    ///
    /// `.sortedKeys` orders struct fields and `String`-keyed dictionaries only, so a dictionary keyed
    /// by an id type wrote equal values as different bytes. The shape is the one the synthesized
    /// `init(from:)` decodes, so files written before and after read the same.
    mutating func encodeInKeyOrder<ID: RawRepresentable & Encodable, Value: Encodable>(
        _ dictionary: [ID: Value], forKey key: Key
    ) throws where ID.RawValue == String {
        var pairs = nestedUnkeyedContainer(forKey: key)
        for (id, value) in dictionary.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try pairs.encode(id)
            try pairs.encode(value)
        }
    }
}
