/// Identifies one pane/session generation for two-pass parent association.
///
/// The pane ID already carries provider instance and connection generation.
/// An optional provider session value additionally prevents pane reuse from
/// inheriting a prior heuristic lock.
public struct NestedAssociationKey: Codable, Hashable, Sendable {
    /// Compound provider-owned pane identity.
    public let paneID: NestedNodeID

    /// Optional provider session value preserved byte-for-byte on the wire.
    public let sessionID: String?

    /// Creates a pane/session association key.
    ///
    /// - Parameters:
    ///   - paneID: Compound provider-owned pane identity.
    ///   - sessionID: Optional opaque session value.
    public init(paneID: NestedNodeID, sessionID: String?) {
        self.paneID = paneID
        self.sessionID = sessionID
    }

    /// Compares pane identity and exact optional provider-session bytes.
    public static func == (lhs: NestedAssociationKey, rhs: NestedAssociationKey) -> Bool {
        lhs.paneID == rhs.paneID
            && lhs.sessionID.map(ExactUTF8String.init)
                == rhs.sessionID.map(ExactUTF8String.init)
    }

    /// Hashes pane identity and exact optional provider-session bytes.
    ///
    /// - Parameter hasher: Hasher receiving the association-key components.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(paneID)
        hasher.combine(sessionID.map(ExactUTF8String.init))
    }

    /// Decodes an association key while preserving opaque session bytes.
    ///
    /// - Parameter decoder: Decoder containing the association key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(NestedNodeID.self, forKey: .paneID)
        sessionID = try container.decodeIfPresent(
            ExactUTF8String.self,
            forKey: .sessionID
        )?.value
    }

    /// Encodes an association key with a byte-exact optional session value.
    ///
    /// - Parameter encoder: Encoder receiving the association key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneID, forKey: .paneID)
        try container.encodeIfPresent(
            sessionID.map(ExactUTF8String.init),
            forKey: .sessionID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case paneID
        case sessionID
    }
}
