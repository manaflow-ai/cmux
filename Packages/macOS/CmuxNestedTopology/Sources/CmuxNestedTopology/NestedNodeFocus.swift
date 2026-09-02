public import Foundation

/// Structured request to focus one virtual nested node on a live attachment.
///
/// Callers must supply the host stable surface and compound node ID. Optional
/// expected attachment / provider-instance values pin mutation authority so a
/// stale generation or wrong host cannot be confused with a live binding.
///
/// Focus never synthesizes keystrokes or shell commands when the provider
/// lacks ``NestedProviderCapability/topologyFocusV1``.
public struct NestedNodeFocusRequest: Hashable, Sendable {
    /// Host cmux stable surface that owns the attachment.
    public let hostStableSurfaceID: UUID
    /// Compound target identity (provider kind + instance + kind + raw ID).
    public let nodeID: NestedNodeID
    /// Optional attachment ID that must match the live binding.
    public let expectedAttachmentID: UUID?
    /// Optional provider instance / connection generation that must match.
    public let expectedProviderInstanceID: NestedProviderInstanceID?
    /// Explicit opt-in authority (UI confirm or authenticated control socket).
    public let authorization: NestedAttachmentAuthorization?

    /// Creates a focus request.
    public init(
        hostStableSurfaceID: UUID,
        nodeID: NestedNodeID,
        expectedAttachmentID: UUID? = nil,
        expectedProviderInstanceID: NestedProviderInstanceID? = nil,
        authorization: NestedAttachmentAuthorization?
    ) {
        self.hostStableSurfaceID = hostStableSurfaceID
        self.nodeID = nodeID
        self.expectedAttachmentID = expectedAttachmentID
        self.expectedProviderInstanceID = expectedProviderInstanceID
        self.authorization = authorization
    }
}

/// Result of an accepted nested focus request.
///
/// Topology focus is reconciled from provider events / resnapshot — this result
/// does **not** invent an optimistic focus record.
public struct NestedNodeFocusResult: Hashable, Codable, Sendable {
    /// Host cmux stable surface that owns the attachment.
    public let hostStableSurfaceID: UUID
    /// Attachment binding that accepted the mutation.
    public let attachmentID: UUID
    /// Provider instance / connection generation at accept time.
    public let providerInstanceID: NestedProviderInstanceID
    /// Compound target that was forwarded to the provider.
    public let nodeID: NestedNodeID
    /// Whether the provider accepted the focus RPC.
    public let accepted: Bool

    enum CodingKeys: String, CodingKey {
        case hostStableSurfaceID = "host_surface_id"
        case attachmentID = "attachment_id"
        case providerInstanceID = "provider_instance_id"
        case nodeID = "node_id"
        case accepted
    }

    /// Creates a focus result.
    public init(
        hostStableSurfaceID: UUID,
        attachmentID: UUID,
        providerInstanceID: NestedProviderInstanceID,
        nodeID: NestedNodeID,
        accepted: Bool
    ) {
        self.hostStableSurfaceID = hostStableSurfaceID
        self.attachmentID = attachmentID
        self.providerInstanceID = providerInstanceID
        self.nodeID = nodeID
        self.accepted = accepted
    }
}
