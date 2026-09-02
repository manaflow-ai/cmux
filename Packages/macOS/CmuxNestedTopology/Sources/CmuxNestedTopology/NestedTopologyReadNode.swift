public import Foundation

/// One provider-owned virtual descendant for control-socket / UI projection.
///
/// Nodes never enter Bonsplit, `Workspace.panels`, or Ghostty PTYs. Identity is
/// always the structured compound ``NestedNodeID``.
public struct NestedTopologyReadNode: Hashable, Codable, Sendable {
    /// Compound node identity.
    public let id: NestedNodeID
    /// Parent compound ID from the stable parent map (`nil` for workspaces).
    public let parentID: NestedNodeID?
    /// Host cmux stable surface identity that owns the attachment.
    public let hostStableSurfaceID: UUID
    /// Attachment that produced this node.
    public let attachmentID: UUID
    /// Provider kind.
    public let providerKind: NestedProviderKind
    /// Provider instance / connection generation when known.
    public let providerInstanceID: NestedProviderInstanceID?
    /// Attachment lifecycle state.
    public let connectionState: NestedConnectionState
    /// Resolved display label after title-lock / sanitization.
    public let label: String
    /// Whether this node is focused in the provider topology.
    public let focused: Bool
    /// Whether the attachment (or node projection) is stale.
    public let stale: Bool
    /// Optional agent decoration (for panes) or agent row identity.
    public let agent: NestedTopologyReadAgentMetadata?
    /// Deterministic sibling order.
    public let orderIndex: Int
    /// Bounded string metadata (never auto-opened as paths/URLs).
    public let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case hostStableSurfaceID = "host_surface_id"
        case attachmentID = "attachment_id"
        case providerKind = "provider_kind"
        case providerInstanceID = "provider_instance_id"
        case connectionState = "state"
        case label
        case focused
        case stale
        case agent
        case orderIndex = "order_index"
        case metadata
    }

    /// Creates a public read node.
    public init(
        id: NestedNodeID,
        parentID: NestedNodeID?,
        hostStableSurfaceID: UUID,
        attachmentID: UUID,
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID?,
        connectionState: NestedConnectionState,
        label: String,
        focused: Bool,
        stale: Bool,
        agent: NestedTopologyReadAgentMetadata? = nil,
        orderIndex: Int,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.parentID = parentID
        self.hostStableSurfaceID = hostStableSurfaceID
        self.attachmentID = attachmentID
        self.providerKind = providerKind
        self.providerInstanceID = providerInstanceID
        self.connectionState = connectionState
        self.label = NestedDisplayStringSanitizer.sanitize(
            label,
            maxUTF8ByteCount: NestedTopologyLimits.default.maxDisplayTitleUTF8ByteCount
        )
        self.focused = focused
        self.stale = stale
        self.agent = agent
        self.orderIndex = orderIndex
        self.metadata = Self.boundedMetadata(metadata)
    }

    /// Technical accessibility tokens for tests/debug (fixed English).
    ///
    /// VoiceOver-facing UI must localize at the SwiftUI boundary
    /// (``NestedSidebarSubtreeView``) from semantic state instead of this value.
    public var accessibilityLabel: String {
        var parts = [id.kind.rawValue, label]
        if focused {
            parts.append("focused")
        }
        if stale || connectionState == .stale {
            parts.append("stale")
        } else if connectionState == .disconnected {
            parts.append("disconnected")
        }
        if let status = agent?.status {
            parts.append(status.rawValue)
        }
        return parts.joined(separator: ", ")
    }

    private static let maxMetadataEntries = 8
    private static let maxMetadataKeyUTF8ByteCount = 64
    private static let maxMetadataValueUTF8ByteCount = 256

    private static func boundedMetadata(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in metadata.keys.sorted() {
            guard result.count < maxMetadataEntries else { break }
            let sanitizedKey = NestedDisplayStringSanitizer.sanitize(
                key,
                maxUTF8ByteCount: maxMetadataKeyUTF8ByteCount
            )
            guard !sanitizedKey.isEmpty else { continue }
            let sanitizedValue = NestedDisplayStringSanitizer.sanitize(
                metadata[key] ?? "",
                maxUTF8ByteCount: maxMetadataValueUTF8ByteCount
            )
            result[sanitizedKey] = sanitizedValue
        }
        return result
    }
}
