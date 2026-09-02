public import Foundation

/// Opt-in / reattach policy persisted with attachment intent.
///
/// Auto-reattach is only safe when durable provider instance identity proof is
/// available and matches the last verified value after fresh security checks.
public enum NestedAttachmentReattachPolicy: String, Hashable, Codable, Sendable, CaseIterable {
    /// Persist intent but never auto-connect; require explicit confirmation.
    case requireConfirmation = "require_confirmation"
    /// Auto-reattach only when provider instance identity matches last verified.
    case autoIfProviderInstanceMatches = "auto_if_provider_instance_matches"
}

/// Non-secret endpoint locator approved for persistence (path only).
///
/// Never includes bearer tokens, credentials, or provider payloads.
public struct NestedAttachmentEndpointLocator: Hashable, Codable, Sendable {
    /// Absolute local Unix socket path previously validated and user-approved.
    public var socketPath: String

    enum CodingKeys: String, CodingKey {
        case socketPath = "socket_path"
    }

    /// Creates an endpoint locator with a sanitized path.
    public init(socketPath: String) {
        self.socketPath = NestedDisplayStringSanitizer.sanitize(
            socketPath,
            maxUTF8ByteCount: NestedUnixSocketEndpointValidator.maxSocketPathUTF8ByteCount
        )
    }
}

/// Versioned attachment *intent* persisted in cmux session snapshots (PR 6).
///
/// ## Persistence rules
///
/// - Persist opt-in / reattach policy, provider kind, and optional non-secret
///   endpoint locator plus last verified provider instance ID for comparison.
/// - Do **not** persist nested node snapshots, output, tokens, bearer credentials,
///   or plugin association state files / records.
/// - Older session snapshots without this field must still decode (optional default).
public struct NestedAttachmentIntentDescriptor: Hashable, Codable, Sendable {
    /// Current schema version for newly written descriptors.
    public static let currentSchemaVersion = 1

    /// Descriptor schema version.
    public var schemaVersion: Int
    /// Provider kind the host surface was attached to.
    public var providerKind: NestedProviderKind
    /// Whether restore may auto-reattach or must confirm.
    public var reattachPolicy: NestedAttachmentReattachPolicy
    /// Approved non-secret endpoint locator, if any.
    public var endpointLocator: NestedAttachmentEndpointLocator?
    /// Last verified provider instance ID used as a comparison value on restore.
    public var lastVerifiedProviderInstanceID: NestedProviderInstanceID?
    /// Whether ``lastVerifiedProviderInstanceID`` came from durable provider proof
    /// (e.g. Herdr `ping.instance_id`). Minted connection generations are not proof.
    public var providerInstanceIdentityProofAvailable: Bool
    /// Last verified socket file identity (device/inode) for path-swap detection.
    public var lastVerifiedFileIdentity: NestedUnixSocketFileIdentity?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case providerKind = "provider_kind"
        case reattachPolicy = "reattach_policy"
        case endpointLocator = "endpoint_locator"
        case lastVerifiedProviderInstanceID = "last_verified_provider_instance_id"
        case providerInstanceIdentityProofAvailable = "provider_instance_identity_proof_available"
        case lastVerifiedFileIdentity = "last_verified_file_identity"
    }

    /// Creates a versioned attachment intent descriptor.
    public init(
        schemaVersion: Int = NestedAttachmentIntentDescriptor.currentSchemaVersion,
        providerKind: NestedProviderKind,
        reattachPolicy: NestedAttachmentReattachPolicy,
        endpointLocator: NestedAttachmentEndpointLocator? = nil,
        lastVerifiedProviderInstanceID: NestedProviderInstanceID? = nil,
        providerInstanceIdentityProofAvailable: Bool = false,
        lastVerifiedFileIdentity: NestedUnixSocketFileIdentity? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.providerKind = providerKind
        self.reattachPolicy = reattachPolicy
        self.endpointLocator = endpointLocator
        self.lastVerifiedProviderInstanceID = lastVerifiedProviderInstanceID
        self.providerInstanceIdentityProofAvailable = providerInstanceIdentityProofAvailable
        self.lastVerifiedFileIdentity = lastVerifiedFileIdentity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? NestedAttachmentIntentDescriptor.currentSchemaVersion
        providerKind = try container.decode(NestedProviderKind.self, forKey: .providerKind)
        reattachPolicy = try container.decodeIfPresent(
            NestedAttachmentReattachPolicy.self,
            forKey: .reattachPolicy
        ) ?? .requireConfirmation
        endpointLocator = try container.decodeIfPresent(
            NestedAttachmentEndpointLocator.self,
            forKey: .endpointLocator
        )
        lastVerifiedProviderInstanceID = try container.decodeIfPresent(
            NestedProviderInstanceID.self,
            forKey: .lastVerifiedProviderInstanceID
        )
        providerInstanceIdentityProofAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .providerInstanceIdentityProofAvailable
        ) ?? false
        lastVerifiedFileIdentity = try container.decodeIfPresent(
            NestedUnixSocketFileIdentity.self,
            forKey: .lastVerifiedFileIdentity
        )
    }

    /// Builds persistence intent from a live/stale attachment record.
    ///
    /// Returns `nil` when there is no approved endpoint to persist (nothing to restore).
    public static func make(from record: NestedAttachmentRecord) -> NestedAttachmentIntentDescriptor? {
        guard let endpoint = record.endpoint else { return nil }
        switch record.state {
        case .live, .stale:
            break
        case .connecting, .disconnected, .incompatible, .rejected:
            return nil
        }

        let proofAvailable = record.providerInstanceIdentityProofAvailable
            && record.providerInstanceID != nil
        let policy: NestedAttachmentReattachPolicy = proofAvailable
            ? .autoIfProviderInstanceMatches
            : .requireConfirmation

        return NestedAttachmentIntentDescriptor(
            schemaVersion: currentSchemaVersion,
            providerKind: record.providerKind,
            reattachPolicy: policy,
            endpointLocator: NestedAttachmentEndpointLocator(socketPath: endpoint.canonicalPath),
            lastVerifiedProviderInstanceID: record.providerInstanceID,
            providerInstanceIdentityProofAvailable: proofAvailable,
            lastVerifiedFileIdentity: endpoint.fileIdentity
        )
    }

    /// Whether restore may attempt unattended auto-reattach under this intent.
    public var allowsUnattendedAutoReattach: Bool {
        reattachPolicy == .autoIfProviderInstanceMatches
            && providerInstanceIdentityProofAvailable
            && lastVerifiedProviderInstanceID != nil
            && lastVerifiedFileIdentity != nil
            && endpointLocator != nil
            && !(endpointLocator?.socketPath.isEmpty ?? true)
    }

    /// Keys that must never appear in encoded intent JSON (secrets / live topology).
    public static let forbiddenPersistenceKeys: Set<String> = [
        "latest_snapshot",
        "snapshot",
        "nodes",
        "workspaces",
        "tabs",
        "panes",
        "agents",
        "output",
        "token",
        "tokens",
        "bearer",
        "credential",
        "credentials",
        "authorization",
        "association",
        "associations",
        "association_store",
        "plugin_association",
        "password",
        "secret",
    ]
}

extension NestedAttachmentIntentDescriptor {
    /// Recursively collects JSON object keys for forbidden-key audits in tests.
    public static func collectJSONKeys(_ value: Any) -> Set<String> {
        var keys = Set<String>()
        if let object = value as? [String: Any] {
            for (key, child) in object {
                keys.insert(key)
                keys.formUnion(collectJSONKeys(child))
            }
        } else if let array = value as? [Any] {
            for child in array {
                keys.formUnion(collectJSONKeys(child))
            }
        }
        return keys
    }
}
