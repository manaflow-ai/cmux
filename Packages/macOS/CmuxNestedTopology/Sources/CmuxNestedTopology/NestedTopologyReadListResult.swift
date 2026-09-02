/// Result payload for `nested.topology.list`.
public struct NestedTopologyReadListResult: Hashable, Codable, Sendable {
    /// Public encoding version for this list payload.
    public static let currentEncodingVersion: UInt8 = 1

    /// Encoding schema version.
    public let encodingVersion: UInt8
    /// Advertised cmux nested-topology capabilities for this build.
    public let capabilities: [NestedTopologyPublicCapability]
    /// Attachments in deterministic host-surface / attachment-id order.
    public let attachments: [NestedTopologyReadAttachment]

    enum CodingKeys: String, CodingKey {
        case encodingVersion = "encoding_version"
        case capabilities
        case attachments
    }

    /// Creates a list result.
    public init(
        encodingVersion: UInt8 = NestedTopologyReadListResult.currentEncodingVersion,
        capabilities: [NestedTopologyPublicCapability] = [.readV1, .focusV1],
        attachments: [NestedTopologyReadAttachment]
    ) {
        self.encodingVersion = encodingVersion
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.attachments = attachments.sorted { lhs, rhs in
            if lhs.hostStableSurfaceID != rhs.hostStableSurfaceID {
                return lhs.hostStableSurfaceID.uuidString < rhs.hostStableSurfaceID.uuidString
            }
            return lhs.attachmentID.uuidString < rhs.attachmentID.uuidString
        }
    }
}
