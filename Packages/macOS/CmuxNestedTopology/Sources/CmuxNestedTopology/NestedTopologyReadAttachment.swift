public import Foundation

/// One attachment summary in a nested topology read list response.
public struct NestedTopologyReadAttachment: Hashable, Codable, Sendable {
    /// Attachment identity.
    public let attachmentID: UUID
    /// Host cmux workspace ID (runtime lookup aid).
    public let hostWorkspaceID: String
    /// Host cmux stable surface identity.
    public let hostStableSurfaceID: UUID
    /// Provider kind.
    public let providerKind: NestedProviderKind
    /// Provider instance / connection generation when known.
    public let providerInstanceID: NestedProviderInstanceID?
    /// Attachment lifecycle state.
    public let state: NestedConnectionState
    /// Negotiated provider capabilities (sorted raw values).
    public let providerCapabilities: [String]
    /// Whether competing plugin writers are suppressed.
    public let pluginWriterHandoffActive: Bool
    /// Redacted last error class, if any.
    public let lastErrorClass: String?
    /// Virtual descendant nodes in deterministic order.
    public let nodes: [NestedTopologyReadNode]

    enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case hostWorkspaceID = "host_workspace_id"
        case hostStableSurfaceID = "host_surface_id"
        case providerKind = "provider_kind"
        case providerInstanceID = "provider_instance_id"
        case state
        case providerCapabilities = "provider_capabilities"
        case pluginWriterHandoffActive = "plugin_writer_handoff_active"
        case lastErrorClass = "last_error_class"
        case nodes
    }

    /// Creates an attachment read summary.
    public init(
        attachmentID: UUID,
        hostWorkspaceID: String,
        hostStableSurfaceID: UUID,
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID?,
        state: NestedConnectionState,
        providerCapabilities: [String],
        pluginWriterHandoffActive: Bool,
        lastErrorClass: String?,
        nodes: [NestedTopologyReadNode]
    ) {
        self.attachmentID = attachmentID
        self.hostWorkspaceID = NestedDisplayStringSanitizer.sanitize(
            hostWorkspaceID,
            maxUTF8ByteCount: NestedAttachmentLimits.default.maxHostWorkspaceIDUTF8ByteCount
        )
        self.hostStableSurfaceID = hostStableSurfaceID
        self.providerKind = providerKind
        self.providerInstanceID = providerInstanceID
        self.state = state
        self.providerCapabilities = providerCapabilities.sorted()
        self.pluginWriterHandoffActive = pluginWriterHandoffActive
        self.lastErrorClass = lastErrorClass
        self.nodes = nodes
    }
}
