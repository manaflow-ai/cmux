// The payload and coalescing attributes of the schema (MethodTable.swift).

/// The schema `payload`.
public enum MethodPayload: Hashable, Sendable {
    case json
    /// A fixed little-endian layout; the first payload byte is the version.
    case binary(layoutVersion: UInt8)
}

/// The schema `coalesce`: a queued, unsent item with equal `key` fields is
/// replaced by a newer one; `additive` fields are summed.
public struct MethodCoalesce: Hashable, Sendable {
    public let key: [String]
    public let additive: [String]

    public init(key: [String], additive: [String]) {
        self.key = key
        self.additive = additive
    }
}
