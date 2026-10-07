import Foundation

/// Caches one host's ICE configuration until shortly before its TURN
/// credentials expire, so connects and ICE restarts reuse one minting call.
actor ICEConfigurationCache {
    private let provider: any ICEServerProvider
    private let margin: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: ICEConfiguration] = [:]

    init(provider: any ICEServerProvider, margin: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.margin = margin
        self.now = now
    }

    func configuration(for hostID: String, refresh: Bool = false) async throws -> ICEConfiguration {
        if !refresh, let cached = entries[hostID], let expiry = cached.expiresAt,
           expiry.timeIntervalSince(now()) > margin {
            return cached
        }
        let fresh = try await provider.iceConfiguration(for: hostID)
        if fresh.expiresAt != nil { entries[hostID] = fresh } else { entries[hostID] = nil }
        return fresh
    }
}
