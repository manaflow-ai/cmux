public import Foundation

/// One nested-provider attachment bound to a host cmux terminal surface.
///
/// Attachments are owned by an app/window-scoped coordinator, never by a SwiftUI
/// row. Closing the host surface detaches this record without invoking
/// `server.stop` or closing provider child panes.
public struct NestedAttachmentRecord: Hashable, Codable, Sendable {
    /// Stable identifier for this attachment binding.
    public var attachmentID: UUID
    /// Host cmux workspace ID (updated when the surface moves).
    public var hostWorkspaceID: String
    /// Host cmux stable surface identity (attachment key; preserved across moves).
    public var hostStableSurfaceID: UUID
    /// Provider kind.
    public var providerKind: NestedProviderKind
    /// Validated endpoint (path + pre-connect file identity). Cleared when detached.
    public var endpoint: NestedAttachmentEndpoint?
    /// Provider instance ID / connection generation after a successful handshake.
    public var providerInstanceID: NestedProviderInstanceID?
    /// Whether ``providerInstanceID`` is durable provider proof (safe for restore compare).
    public var providerInstanceIdentityProofAvailable: Bool
    /// Negotiated capabilities after a successful handshake.
    public var capabilities: NestedCapabilitySet
    /// Lifecycle state.
    public var state: NestedConnectionState
    /// Whether the plugin single-writer handoff is currently held for this attachment.
    public var pluginWriterHandoffActive: Bool
    /// Redacted last error class (never a socket path or payload).
    public var lastErrorClass: String?
    /// Latest topology snapshot while live/stale, if any.
    ///
    /// In-memory only for UI/control-socket reads — never persisted into session
    /// snapshots (see ``NestedAttachmentIntentDescriptor``).
    public var latestSnapshot: NestedTopologySnapshot?
    /// Persisted restore intent awaiting confirmation, if any (PR 6).
    public var pendingRestoreIntent: NestedAttachmentIntentDescriptor?

    enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case hostWorkspaceID = "host_workspace_id"
        case hostStableSurfaceID = "host_stable_surface_id"
        case providerKind = "provider_kind"
        case endpoint
        case providerInstanceID = "provider_instance_id"
        case providerInstanceIdentityProofAvailable = "provider_instance_identity_proof_available"
        case capabilities
        case state
        case pluginWriterHandoffActive = "plugin_writer_handoff_active"
        case lastErrorClass = "last_error_class"
        case pendingRestoreIntent = "pending_restore_intent"
    }

    /// Creates an attachment record.
    public init(
        attachmentID: UUID = UUID(),
        hostWorkspaceID: String,
        hostStableSurfaceID: UUID,
        providerKind: NestedProviderKind,
        endpoint: NestedAttachmentEndpoint? = nil,
        providerInstanceID: NestedProviderInstanceID? = nil,
        providerInstanceIdentityProofAvailable: Bool = false,
        capabilities: NestedCapabilitySet = NestedCapabilitySet(),
        state: NestedConnectionState = .disconnected,
        pluginWriterHandoffActive: Bool = false,
        lastErrorClass: String? = nil,
        latestSnapshot: NestedTopologySnapshot? = nil,
        pendingRestoreIntent: NestedAttachmentIntentDescriptor? = nil
    ) {
        self.attachmentID = attachmentID
        self.hostWorkspaceID = NestedDisplayStringSanitizer.sanitize(
            hostWorkspaceID,
            maxUTF8ByteCount: NestedAttachmentLimits.default.maxHostWorkspaceIDUTF8ByteCount
        )
        self.hostStableSurfaceID = hostStableSurfaceID
        self.providerKind = providerKind
        self.endpoint = endpoint
        self.providerInstanceID = providerInstanceID
        self.providerInstanceIdentityProofAvailable = providerInstanceIdentityProofAvailable
        self.capabilities = capabilities
        self.state = state
        self.pluginWriterHandoffActive = pluginWriterHandoffActive
        self.lastErrorClass = lastErrorClass
        self.latestSnapshot = latestSnapshot
        self.pendingRestoreIntent = pendingRestoreIntent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachmentID = try container.decode(UUID.self, forKey: .attachmentID)
        hostWorkspaceID = try container.decode(String.self, forKey: .hostWorkspaceID)
        hostStableSurfaceID = try container.decode(UUID.self, forKey: .hostStableSurfaceID)
        providerKind = try container.decode(NestedProviderKind.self, forKey: .providerKind)
        endpoint = try container.decodeIfPresent(NestedAttachmentEndpoint.self, forKey: .endpoint)
        providerInstanceID = try container.decodeIfPresent(
            NestedProviderInstanceID.self,
            forKey: .providerInstanceID
        )
        providerInstanceIdentityProofAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .providerInstanceIdentityProofAvailable
        ) ?? false
        capabilities = try container.decodeIfPresent(NestedCapabilitySet.self, forKey: .capabilities)
            ?? NestedCapabilitySet()
        state = try container.decodeIfPresent(NestedConnectionState.self, forKey: .state)
            ?? .disconnected
        pluginWriterHandoffActive = try container.decodeIfPresent(
            Bool.self,
            forKey: .pluginWriterHandoffActive
        ) ?? false
        lastErrorClass = try container.decodeIfPresent(String.self, forKey: .lastErrorClass)
        // Live topology is never persisted with the attachment record.
        latestSnapshot = nil
        pendingRestoreIntent = try container.decodeIfPresent(
            NestedAttachmentIntentDescriptor.self,
            forKey: .pendingRestoreIntent
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attachmentID, forKey: .attachmentID)
        try container.encode(hostWorkspaceID, forKey: .hostWorkspaceID)
        try container.encode(hostStableSurfaceID, forKey: .hostStableSurfaceID)
        try container.encode(providerKind, forKey: .providerKind)
        try container.encodeIfPresent(endpoint, forKey: .endpoint)
        try container.encodeIfPresent(providerInstanceID, forKey: .providerInstanceID)
        try container.encode(
            providerInstanceIdentityProofAvailable,
            forKey: .providerInstanceIdentityProofAvailable
        )
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(state, forKey: .state)
        try container.encode(pluginWriterHandoffActive, forKey: .pluginWriterHandoffActive)
        try container.encodeIfPresent(lastErrorClass, forKey: .lastErrorClass)
        try container.encodeIfPresent(pendingRestoreIntent, forKey: .pendingRestoreIntent)
    }

    /// Whether the attachment currently suppresses competing plugin writers.
    public var suppressesPluginWriters: Bool {
        pluginWriterHandoffActive && state == .live
    }

    /// Session-snapshot persistence intent for this attachment, if any.
    public var sessionPersistenceIntent: NestedAttachmentIntentDescriptor? {
        NestedAttachmentIntentDescriptor.make(from: self)
    }
}
