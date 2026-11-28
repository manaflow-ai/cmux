import Foundation

extension CmxIrohHostRuntimeConfiguration {
    func resolvedEndpointRelayProfile(now: Date) throws -> CmxIrohEndpointRelayProfile {
        try resolveEndpointRelayProfile(
            configured: endpointRelayProfile,
            managedRelayURLs: managedRelayURLs,
            cachedRelayCredential: cachedRelayCredential,
            now: now
        )
    }
}

extension CmxIrohClientRuntimeConfiguration {
    func resolvedEndpointRelayProfile(now: Date) throws -> CmxIrohEndpointRelayProfile {
        try resolveEndpointRelayProfile(
            configured: endpointRelayProfile,
            managedRelayURLs: managedRelayURLs,
            cachedRelayCredential: cachedRelayCredential,
            now: now
        )
    }
}

private func resolveEndpointRelayProfile(
    configured: CmxIrohEndpointRelayProfile?,
    managedRelayURLs: Set<String>,
    cachedRelayCredential: CmxIrohRelayTokenResponse?,
    now: Date
) throws -> CmxIrohEndpointRelayProfile {
    let base = try configured ?? CmxIrohEndpointRelayProfile(
        managedRelayURLs: managedRelayURLs,
        relays: []
    )
    guard base.source == .managed,
          let cachedRelayCredential,
          cachedRelayCredential.relayFleet.count == managedRelayURLs.count,
          Set(cachedRelayCredential.relayFleet) == managedRelayURLs,
          let cached = try? cachedRelayCredential.relayConfigurations(now: now) else {
        return base
    }
    let selected = cached.filter { base.allowedRelayURLs.contains($0.url) }
    guard selected.count == base.allowedRelayURLs.count else { return base }
    return try base.replacingManagedRelays(selected)
}
