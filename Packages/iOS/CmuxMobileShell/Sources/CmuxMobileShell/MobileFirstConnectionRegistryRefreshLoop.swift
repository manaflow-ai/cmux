/// Runs first-connection registry renewal independently from presence polling.
///
/// The loop owns one renewal at a time and exits when its task is cancelled or
/// the caller's discovery scope is no longer current.
public struct MobileFirstConnectionRegistryRefreshLoop: Sendable {
    /// Timing applied between renewal attempts.
    public let policy: MobileFirstConnectionRegistryRefreshPolicy

    /// Creates an independent registry renewal loop.
    /// - Parameter policy: Timing applied between renewal attempts.
    public init(policy: MobileFirstConnectionRegistryRefreshPolicy = .init()) {
        self.policy = policy
    }

    /// Runs renewals until cancellation or discovery-scope invalidation.
    ///
    /// The next delay begins only after `refresh` returns, which guarantees one
    /// renewal at a time even when a registry request is slow.
    /// - Parameters:
    ///   - clock: Clock that controls renewal timing and supports deterministic tests.
    ///   - whileCurrent: Returns whether the owning discovery scope is still current.
    ///   - refresh: Performs one authoritative registry refresh.
    public func run(
        clock: any Clock<Duration> = ContinuousClock(),
        whileCurrent: @escaping @MainActor () -> Bool,
        refresh: @escaping @MainActor () async -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: policy.refreshInterval)
            } catch {
                return
            }
            guard !Task.isCancelled, await whileCurrent() else { return }
            await refresh()
        }
    }
}
