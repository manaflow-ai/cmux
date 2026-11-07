public import Foundation

/// Actor-isolated cache around task model discovery for each provider installation.
public actor MobileTaskModelDiscovery {
    /// Reads the current host setting for a custom Claude executable.
    public typealias CustomClaudePath = @Sendable () async -> String?
    /// Asynchronous clock read used for cache expiry.
    public typealias Now = @Sendable () async -> Date

    private struct CacheEntry {
        let result: MobileTaskModelListResult
        let fetchedAt: Date
    }

    private struct CacheKey: Hashable {
        let provider: MobileTaskModelProvider
        let claudeExecutable: String
    }

    /// Default lifetime for one provider's discovered result.
    public static let defaultCacheTTL: TimeInterval = 10 * 60

    private let strategy: MobileTaskModelProviderStrategy
    private let now: Now
    private let cacheTTL: TimeInterval
    private let customClaudePath: CustomClaudePath
    private var cache: [CacheKey: CacheEntry] = [:]
    private var inFlight: [
        CacheKey: Task<MobileTaskModelListResult, Never>
    ] = [:]

    /// Creates a cached discovery service.
    ///
    /// - Parameters:
    ///   - strategy: Provider-specific discovery implementation.
    ///   - now: Injected clock read.
    ///   - cacheTTL: Cache lifetime in seconds.
    ///   - customClaudePath: Current host setting; `nil` uses login-shell `PATH`.
    public init(
        strategy: MobileTaskModelProviderStrategy,
        now: @escaping Now = { Date() },
        cacheTTL: TimeInterval = MobileTaskModelDiscovery.defaultCacheTTL,
        customClaudePath: @escaping CustomClaudePath = { nil }
    ) {
        self.strategy = strategy
        self.now = now
        self.cacheTTL = cacheTTL
        self.customClaudePath = customClaudePath
    }

    /// Creates the production discovery service for the current user.
    ///
    /// - Parameters:
    ///   - homeDirectory: Current user's home directory.
    ///   - shellPath: Login shell used to resolve the user's CLI `PATH`.
    ///   - customClaudePath: Reads the host setting on each discovery request.
    /// - Returns: A ten-minute cached discovery actor.
    public static func live(
        homeDirectory: URL,
        shellPath: String,
        customClaudePath: @escaping CustomClaudePath = { nil }
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
        return MobileTaskModelDiscovery(strategy: strategy, customClaudePath: customClaudePath)
    }

    /// Returns a fresh cached result or performs one coalesced discovery.
    ///
    /// - Parameter provider: Provider whose models are requested.
    /// - Returns: Agent-discovered models, or an empty fallback result.
    public func models(
        for provider: MobileTaskModelProvider
    ) async -> MobileTaskModelListResult {
        let configuredPath = provider == .claude
            ? await customClaudePath()?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let claudeExecutable = configuredPath.flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
        let key = CacheKey(provider: provider, claudeExecutable: claudeExecutable)
        let currentTime = await now()
        if let cached = cache[key],
           currentTime.timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.result
        }
        if let pending = inFlight[key] {
            return await pending.value
        }

        let strategy = self.strategy
        let pending = Task {
            await strategy.models(for: provider, claudeExecutable: claudeExecutable)
        }
        inFlight[key] = pending
        let result = await pending.value
        // A failed probe is a snapshot of a transient command or provider
        // state. Keep successful catalogs cached, but let the next request
        // retry failures instead of replaying a stale error for ten minutes.
        if result.error == nil {
            cache[key] = CacheEntry(result: result, fetchedAt: await now())
        }
        inFlight[key] = nil
        return result
    }
}
