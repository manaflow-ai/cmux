import Foundation

/// The complete relay policy installed on one Iroh endpoint generation.
///
/// Managed relays carry no client credentials: the relay handshake proves the
/// endpoint key and the relay's server-side allow hook decides admission.
/// Custom relays may still carry a user-configured static token.
public struct CmxIrohEndpointRelayProfile: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case managed
        case custom
    }

    struct Relay: Equatable, Sendable {
        let url: String
        let authenticationToken: String?
    }

    /// Exact relay origins accepted in peer reachability hints.
    public let allowedRelayURLs: Set<String>

    /// Whether this profile installs at least one dialable relay (an
    /// unavailable or empty selection dials none). Composition roots use
    /// this to decide whether a restored cached policy can carry a
    /// relay-only activation.
    public var hasDialableRelays: Bool { !activeRelays.isEmpty }

    let source: Source
    let activeRelays: [Relay]

    /// A fail-closed profile used when a selected custom relay profile cannot
    /// be restored. Direct P2P stays enabled, while every relay is disabled.
    public static let unavailableCustomOverride = CmxIrohEndpointRelayProfile(
        allowedRelayURLs: [],
        source: .custom,
        activeRelays: []
    )

    /// A fail-closed profile used when a managed relay selection cannot be
    /// honored. Direct P2P stays enabled, while every relay is disabled.
    public static let unavailableManagedSelection = CmxIrohEndpointRelayProfile(
        allowedRelayURLs: [],
        source: .managed,
        activeRelays: []
    )

    private init(
        allowedRelayURLs: Set<String>,
        source: Source,
        activeRelays: [Relay]
    ) {
        self.allowedRelayURLs = allowedRelayURLs
        self.source = source
        self.activeRelays = activeRelays
    }

    /// Creates a managed profile in which every allowed relay is active with
    /// no client credential.
    ///
    /// - Parameter allowedRelayURLs: Exact managed relay origins accepted by policy.
    /// - Throws: ``CmxIrohEndpointConfigurationError`` for a policy violation.
    public init(managedRelayURLs allowedRelayURLs: Set<String>) throws {
        guard allowedRelayURLs.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount else {
            throw CmxIrohEndpointConfigurationError.tooManyRelays(allowedRelayURLs.count)
        }
        self.allowedRelayURLs = allowedRelayURLs
        source = .managed
        activeRelays = allowedRelayURLs.sorted().map {
            Relay(url: $0, authenticationToken: nil)
        }
    }

    /// Creates a managed profile from one verified catalog selection.
    ///
    /// - Parameter snapshot: Root-verified managed catalog and local selection.
    /// - Throws: ``CmxIrohEndpointConfigurationError`` for a policy violation.
    public init(snapshot: CmxIrohRelayPolicySnapshot) throws {
        try self.init(managedRelayURLs: snapshot.relayURLs)
    }

    /// Creates a strict custom override with no managed-provider fallback.
    ///
    /// Direct peer-to-peer paths remain enabled by Iroh. This profile controls
    /// only which relays may carry traffic when direct connectivity is unavailable.
    ///
    /// - Parameter customProfile: User-controlled relays and optional static tokens.
    public init(customProfile: CmxIrohCustomRelayProfile) {
        allowedRelayURLs = Set(customProfile.relays.map(\.url))
        source = .custom
        activeRelays = customProfile.relays.map {
            Relay(
                url: $0.url,
                authenticationToken: $0.authenticationToken
            )
        }
    }
}
