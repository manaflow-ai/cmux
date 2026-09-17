public import Foundation

/// Redacted attachment lifecycle telemetry event.
///
/// Never includes socket paths, provider payloads, or raw display strings.
public struct NestedAttachmentTelemetryEvent: Hashable, Codable, Sendable {
    /// Provider kind when known.
    public var providerKind: NestedProviderKind?
    /// Attachment lifecycle state.
    public var state: NestedConnectionState
    /// Coarse error class, if any.
    public var errorClass: String?
    /// Event name (`attach_started`, `attach_live`, `detached`, …).
    public var name: String
    /// Host stable surface ID (UUID only; not a filesystem path).
    public var hostStableSurfaceID: UUID?
    /// Attachment ID when assigned.
    public var attachmentID: UUID?

    enum CodingKeys: String, CodingKey {
        case providerKind = "provider_kind"
        case state
        case errorClass = "error_class"
        case name
        case hostStableSurfaceID = "host_stable_surface_id"
        case attachmentID = "attachment_id"
    }

    /// Creates a redacted telemetry event.
    public init(
        name: String,
        state: NestedConnectionState,
        providerKind: NestedProviderKind? = nil,
        errorClass: String? = nil,
        hostStableSurfaceID: UUID? = nil,
        attachmentID: UUID? = nil
    ) {
        self.name = name
        self.state = state
        self.providerKind = providerKind
        self.errorClass = errorClass
        self.hostStableSurfaceID = hostStableSurfaceID
        self.attachmentID = attachmentID
    }
}
