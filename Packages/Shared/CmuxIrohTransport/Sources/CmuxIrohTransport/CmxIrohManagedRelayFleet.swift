/// Selects the token issuer associated with one managed relay deployment.
public enum CmxIrohRelayTokenEndpoint: Equatable, Sendable {
    /// The new cmux fleet accepts an EndpointID-bound JWT from `/api/relay/token`.
    case selfHosted

    /// The migration fleet accepts a binding-scoped token from the trust broker.
    case legacyTrustBroker
}

/// One exact relay allowlist and its matching authenticated token issuer.
public struct CmxIrohRelayDeployment: Equatable, Sendable {
    /// The exact canonical HTTPS origins accepted for this deployment.
    public let urls: Set<String>

    /// The API contract that issues credentials for these relay origins.
    public let tokenEndpoint: CmxIrohRelayTokenEndpoint

    /// Creates a relay deployment whose allowlist and issuer cannot diverge.
    public init(urls: Set<String>, tokenEndpoint: CmxIrohRelayTokenEndpoint) {
        self.urls = urls
        self.tokenEndpoint = tokenEndpoint
    }
}

/// Relay deployments accepted by cmux during the self-hosted rollout.
public extension CmxIrohRelayDeployment {
    /// The seven-region endpoint-authenticated cmux fleet.
    static let selfHosted = CmxIrohRelayDeployment(
        urls: [
            "https://ape1.relay.cmux.dev/",
            "https://apne1.relay.cmux.dev/",
            "https://apse1.relay.cmux.dev/",
            "https://euw4.relay.cmux.dev/",
            "https://usc1.relay.cmux.dev/",
            "https://use4.relay.cmux.dev/",
            "https://usw1.relay.cmux.dev/",
        ],
        tokenEndpoint: .selfHosted
    )

    /// The pre-migration hosted fleet retained as the Release safety gate.
    static let legacy = CmxIrohRelayDeployment(
        urls: [
            "https://aps1-1.relay.lawrence.cmux.iroh.link/",
            "https://euc1-1.relay.lawrence.cmux.iroh.link/",
            "https://use1-1.relay.lawrence.cmux.iroh.link/",
            "https://usw1-1.relay.lawrence.cmux.iroh.link/",
        ],
        tokenEndpoint: .legacyTrustBroker
    )

    /// Tagged development builds exercise self-hosted relays. Release stays on
    /// the legacy fleet until account-level caps or expiry disconnects ship.
    static let current: CmxIrohRelayDeployment = {
        #if DEBUG
        selfHosted
        #else
        legacy
        #endif
    }()
}
