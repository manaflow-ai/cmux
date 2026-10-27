public import CmuxNextCompat

/// The local daemon's memory limit as one consumer of the app's memory coordinator (p07-memory-109): the
/// coordinator hands it each level and Memory Saver mode, and it tells its ``DaemonMemoryLimitFollow`` the limit the
/// coordinator acts on now, as Chrome's `ChildMemoryConsumerRegistryHost` stands in the browser's registry for a
/// child process's consumers (content/browser/memory_coordinator/README.md). It holds nothing, so it releases
/// nothing; it is lossy, so each level reaches it at once, never held by the lossless hysteresis.
@MainActor
public final class DaemonMemoryLimitLink: MemoryLevelConsumer, MemorySaverModeConsumer {
    /// Its name in the memory report.
    public static let name = "daemon-memory-limit"
    static let traits = MemoryConsumerTraits(
        estimatedUsage: .small, dataAccess: .none, retention: .lossy, recreateCost: .notApplicable,
        releaseCPUCost: .low, isStateful: false, supportsMemoryLimit: false)

    public let follow: DaemonMemoryLimitFollow
    private let limit: @MainActor () -> MemoryLimitRequest
    private var registration: MemoryConsumerRegistration?

    /// Registers with `registry`, which hands it the current level and mode before this returns.
    ///
    /// - Parameters:
    ///   - follow: Tells the local daemon each change.
    ///   - registry: The app's memory coordinator.
    ///   - limit: The limit the coordinator acts on now: its level (the debug override folded in), its mode
    ///     and the override.
    public init(follow: DaemonMemoryLimitFollow, registry: any MemoryConsumerRegistry,
                limit: @escaping @MainActor () -> MemoryLimitRequest) {
        self.follow = follow
        self.limit = limit
        registration = MemoryConsumerRegistration(name: Self.name, traits: Self.traits, consumer: self, registry: registry)
    }

    public func memoryLevelDidChange(_ level: MemoryPressureLevel) { follow.changed(limit()) }
    public func memorySaverModeDidChange(_ mode: MemorySaverMode) { follow.changed(limit()) }
    public func updateMemoryLimit(_ limit: MemoryLimit) {}
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress { .done }
    public var memoryUsage: MemoryUsage? { nil }
}
