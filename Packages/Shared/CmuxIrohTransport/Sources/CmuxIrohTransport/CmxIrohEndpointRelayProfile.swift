import Foundation

/// The complete relay policy installed on one Iroh endpoint generation.
public struct CmxIrohEndpointRelayProfile: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case managed
        case custom
    }

    struct Relay: Equatable, Sendable {
        let url: String
        let authenticationToken: String?
        let expiresAt: Date?

        func isUsable(at now: Date) -> Bool {
            expiresAt.map { $0 > now } ?? true
        }
    }

    /// Exact relay origins accepted in peer reachability hints.
    public let allowedRelayURLs: Set<String>

    let source: Source
    let activeRelays: [Relay]
    let managedRelays: [CmxIrohRelayConfiguration]

    /// A fail-closed profile used when a selected custom relay profile cannot
    /// be restored. Direct P2P stays enabled, while every relay is disabled.
    public static let unavailableCustomOverride = CmxIrohEndpointRelayProfile(
        allowedRelayURLs: [],
        source: .custom,
        activeRelays: [],
        managedRelays: []
    )

    /// A fail-closed profile used when a managed relay selection cannot be
    /// honored. Direct P2P stays enabled, while every relay is disabled.
    public static let unavailableManagedSelection = CmxIrohEndpointRelayProfile(
        allowedRelayURLs: [],
        source: .managed,
        activeRelays: [],
        managedRelays: []
    )

    private init(
        allowedRelayURLs: Set<String>,
        source: Source,
        activeRelays: [Relay],
        managedRelays: [CmxIrohRelayConfiguration]
    ) {
        self.allowedRelayURLs = allowedRelayURLs
        self.source = source
        self.activeRelays = activeRelays
        self.managedRelays = managedRelays
    }

    /// Creates a managed profile whose credentials are constrained by an
    /// app-pinned or root-verified relay allowlist.
    ///
    /// The allowlist may contain relays without a current credential so an
    /// endpoint can bind before broker refresh completes.
    ///
    /// - Parameters:
    ///   - allowedRelayURLs: Exact managed relay origins accepted by policy.
    ///   - relays: Current endpoint-scoped credentials for a subset of the allowlist.
    /// - Throws: ``CmxIrohEndpointConfigurationError`` for a policy violation.
    public init(
        managedRelayURLs allowedRelayURLs: Set<String>,
        relays: [CmxIrohRelayConfiguration]
    ) throws {
        try Self.validate(
            allowedRelayURLs: allowedRelayURLs,
            relayURLs: relays.map(\.url)
        )
        self.allowedRelayURLs = allowedRelayURLs
        source = .managed
        activeRelays = relays.map {
            Relay(
                url: $0.url,
                authenticationToken: $0.token,
                expiresAt: $0.expiresAt
            )
        }
        managedRelays = relays
    }

    /// Creates a managed profile from one verified catalog selection and its
    /// exact endpoint-scoped credential set.
    ///
    /// - Parameters:
    ///   - snapshot: Root-verified managed catalog and local selection.
    ///   - relays: Credentials for every selected relay and no other origin.
    /// - Throws: ``CmxIrohEndpointConfigurationError`` for credential substitution.
    public init(
        snapshot: CmxIrohRelayPolicySnapshot,
        relays: [CmxIrohRelayConfiguration]
    ) throws {
        let selectedURLs = snapshot.relayURLs
        let credentialURLs = Set(relays.map(\.url))
        guard credentialURLs == selectedURLs else {
            if let substituted = credentialURLs.subtracting(selectedURLs).first {
                throw CmxIrohEndpointConfigurationError.unmanagedRelayURL(substituted)
            }
            throw CmxIrohEndpointConfigurationError.incompleteManagedRelayCredentials
        }
        try self.init(managedRelayURLs: selectedURLs, relays: relays)
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
                authenticationToken: $0.authenticationToken,
                expiresAt: nil
            )
        }
        managedRelays = []
    }

    func replacingManagedRelays(
        _ relays: [CmxIrohRelayConfiguration]
    ) throws -> CmxIrohEndpointRelayProfile {
        guard source == .managed else {
            throw CmxIrohEndpointConfigurationError.managedCredentialUpdateInCustomProfile
        }
        return try CmxIrohEndpointRelayProfile(
            managedRelayURLs: allowedRelayURLs,
            relays: relays
        )
    }

    func droppingExpiredManagedCredentials(at now: Date) throws -> CmxIrohEndpointRelayProfile {
        guard source == .managed else { return self }
        return try CmxIrohEndpointRelayProfile(
            managedRelayURLs: allowedRelayURLs,
            relays: managedRelays.filter { $0.expiresAt > now }
        )
    }

    private static func validate(
        allowedRelayURLs: Set<String>,
        relayURLs: [String]
    ) throws {
        guard allowedRelayURLs.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount else {
            throw CmxIrohEndpointConfigurationError.tooManyRelays(allowedRelayURLs.count)
        }
        guard relayURLs.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount else {
            throw CmxIrohEndpointConfigurationError.tooManyRelays(relayURLs.count)
        }
        var observedURLs = Set<String>()
        for url in relayURLs {
            guard allowedRelayURLs.contains(url) else {
                throw CmxIrohEndpointConfigurationError.unmanagedRelayURL(url)
            }
            guard observedURLs.insert(url).inserted else {
                throw CmxIrohEndpointConfigurationError.duplicateRelayURL(url)
            }
        }
    }
}
