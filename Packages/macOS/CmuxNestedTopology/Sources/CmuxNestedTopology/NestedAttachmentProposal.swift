public import Foundation

/// Non-authoritative attachment suggestion for one host surface.
///
/// Proposals may be recorded from environment/OSC hints so the app can prefill
/// an attach UI. They do **not** establish a live attachment and must not be
/// treated as security authority.
public struct NestedAttachmentProposal: Hashable, Codable, Sendable {
    /// Host workspace ID hint when known.
    public var hostWorkspaceID: String?
    /// Host cmux stable surface identity the proposal is bound to.
    public var hostStableSurfaceID: UUID
    /// Suggested provider kind.
    public var providerKind: NestedProviderKind
    /// Suggested socket locator (still subject to security validation on attach).
    public var suggestedSocketPath: String
    /// Where the suggestion came from.
    public var source: NestedAttachmentProposalSource
    /// Wall-clock time the proposal was recorded (for stale-UI hints).
    public var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case hostWorkspaceID = "host_workspace_id"
        case hostStableSurfaceID = "host_stable_surface_id"
        case providerKind = "provider_kind"
        case suggestedSocketPath = "suggested_socket_path"
        case source
        case recordedAt = "recorded_at"
    }

    /// Creates a proposal with sanitized string fields.
    public init(
        hostWorkspaceID: String? = nil,
        hostStableSurfaceID: UUID,
        providerKind: NestedProviderKind,
        suggestedSocketPath: String,
        source: NestedAttachmentProposalSource,
        recordedAt: Date = Date()
    ) {
        self.hostWorkspaceID = hostWorkspaceID.map {
            NestedDisplayStringSanitizer.sanitize($0, maxUTF8ByteCount: 256)
        }
        self.hostStableSurfaceID = hostStableSurfaceID
        self.providerKind = providerKind
        self.suggestedSocketPath = NestedDisplayStringSanitizer.sanitize(
            suggestedSocketPath,
            maxUTF8ByteCount: NestedUnixSocketEndpointValidator.maxSocketPathUTF8ByteCount
        )
        self.source = source
        self.recordedAt = recordedAt
    }
}
