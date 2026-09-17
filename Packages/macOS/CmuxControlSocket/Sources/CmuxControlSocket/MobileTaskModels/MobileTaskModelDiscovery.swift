public import Foundation

/// Actor-isolated, per-provider cache around task model discovery.
public actor MobileTaskModelDiscovery {
    /// Asynchronous clock read used for cache expiry.
    public typealias Now = @Sendable () async -> Date

    private struct CacheEntry {
        let result: MobileTaskModelListResult
        let fetchedAt: Date
    }

    /// Default lifetime for one provider's discovered result.
    public static let defaultCacheTTL: TimeInterval = 10 * 60

    private let strategy: MobileTaskModelProviderStrategy
    private let now: Now
    private let cacheTTL: TimeInterval
    private var cache: [MobileTaskModelProvider: CacheEntry] = [:]
    private var inFlight: [
        MobileTaskModelProvider: Task<MobileTaskModelListResult, Never>
    ] = [:]

    /// Creates a cached discovery service.
    ///
    /// - Parameters:
    ///   - strategy: Provider-specific discovery implementation.
    ///   - now: Injected clock read.
    ///   - cacheTTL: Cache lifetime in seconds.
    public init(
        strategy: MobileTaskModelProviderStrategy,
        now: @escaping Now = { Date() },
        cacheTTL: TimeInterval = MobileTaskModelDiscovery.defaultCacheTTL
    ) {
        self.strategy = strategy
        self.now = now
        self.cacheTTL = cacheTTL
    }

    /// Creates the production discovery service for the current user.
    ///
    /// - Parameters:
    ///   - homeDirectory: Current user's home directory.
    ///   - shellPath: Login shell used to resolve the user's CLI `PATH`.
    /// - Returns: A ten-minute cached discovery actor.
    public static func live(
        homeDirectory: URL,
        shellPath: String
    ) -> MobileTaskModelDiscovery {
        let shellRunner = MobileTaskModelShellRunner(shellPath: shellPath)
        let strategy = MobileTaskModelProviderStrategy(
            homeDirectory: homeDirectory,
            commandRunner: { command, timeout in
                await shellRunner.run(command: command, timeout: timeout)
            },
            fileReader: { url in
                await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url)
                }.value
            }
        )
        return MobileTaskModelDiscovery(strategy: strategy)
    }

    /// Returns a fresh cached result or performs one coalesced discovery.
    ///
    /// - Parameter provider: Provider whose models are requested.
    /// - Returns: Agent-discovered models, or an empty fallback result.
    public func models(
        for provider: MobileTaskModelProvider
    ) async -> MobileTaskModelListResult {
        let currentTime = await now()
        if let cached = cache[provider],
           currentTime.timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.result
        }
        if let pending = inFlight[provider] {
            return await pending.value
        }

        let strategy = self.strategy
        let pending = Task {
            await strategy.models(for: provider)
        }
        inFlight[provider] = pending
        let result = await pending.value
        cache[provider] = CacheEntry(result: result, fetchedAt: await now())
        inFlight[provider] = nil
        return result
    }
}
