import CMUXMobileCore

/// Maps package-private path evidence through one verified effective policy.
struct CmxIrohSelectedTransportPathClassifier: Sendable {
    private let policy: CmxIrohEffectiveRelayPolicy?

    init(policy: CmxIrohEffectiveRelayPolicy?) {
        self.policy = policy
    }

    func classify(
        _ observedPath: CmxIrohObservedConnectionPath
    ) -> CmxIrohSelectedTransportPath {
        switch observedPath {
        case .unavailable:
            return .unavailable
        case .direct:
            return .direct
        case .privateNetwork:
            return .privateNetwork
        case let .relay(url):
            return classifyRelay(url: url)
        }
    }

    private func classifyRelay(url: String) -> CmxIrohSelectedTransportPath {
        guard let policy,
              policy.endpointRelayProfile.allowedRelayURLs.contains(url) else {
            return .unavailable
        }
        switch policy.source {
        case .managed:
            if let relay = policy.managedPolicy?.relays.first(where: { $0.url == url }) {
                return .managedRelay(provider: relay.provider, region: relay.region)
            }
        case .custom:
            if case let .custom(relays) = policy.effectivePreference,
               let relay = relays.first(where: { $0.url == url }) {
                return .customRelay(
                    displayName: relay.displayName ?? relay.id,
                    provider: relay.provider,
                    region: relay.region
                )
            }
        case .inactive, .managedUnavailable, .customUnavailable:
            break
        }
        return .unavailable
    }
}
