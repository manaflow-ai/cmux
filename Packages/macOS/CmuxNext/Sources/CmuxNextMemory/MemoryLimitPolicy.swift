public import CmuxNextCompat

/// The limit ``MemoryCoordinator`` gives one consumer at one pressure level in one Memory Saver mode.
///
/// Chrome's `chrome/browser/performance_manager/policies/memory_saver_memory_coordinator_policy.cc`
/// scales the consumers it manages (`ShouldManageConsumer`: stateful and supporting a limit) by the
/// mode's share. cmux differs at two levels, as p07-memory.md section 3.A decides:
///
/// - Normal: every consumer keeps 100 % in every mode. Its full size already comes from RAM
///   (`SubsystemBudget`), and scaling with no pressure would only cut hit rates of visible content.
/// - Warning: only managed, lossless consumers whose release touches nothing but memory and whose
///   state is cheap to rebuild get the mode's share times 1/2 (medium 25 %). Every other consumer
///   keeps 100 %: macOS WARN is noisy (Chrome's `kSkipModerateMemoryPressureLevelMac`), so nothing
///   expensive or lossy acts on it.
/// - Critical: every consumer goes to 0 % (``MemoryLimit/criticalThreshold``). Lossy and unmanaged
///   consumers get the level only, never a mode share: Chrome's urgent page discarding policy is
///   such a consumer and acts when its limit reaches the critical threshold.
///
/// ```swift
/// let limit = MemoryLimitPolicy(mode: .medium).limit(for: traits, at: .warning)
/// ```
public nonisolated struct MemoryLimitPolicy: Hashable, Sendable {
    /// The share at warning pressure, before the mode's share is applied.
    private static let warningShare = MemoryLimit(percent: 50)

    /// The `memory.saver` mode whose share scales the managed consumers.
    public var mode: MemorySaverMode

    /// Makes the policy of `mode`.
    ///
    /// - Parameter mode: The Memory Saver mode.
    public init(mode: MemorySaverMode) {
        self.mode = mode
    }

    /// The limit of a consumer with `traits` at `level`.
    ///
    /// - Parameters:
    ///   - traits: The consumer's traits.
    ///   - level: The pressure level the coordinator acts on (the debug override or the kernel's).
    /// - Returns: The share of its full size the consumer may keep.
    public func limit(for traits: MemoryConsumerTraits, at level: MemoryPressureLevel) -> MemoryLimit {
        switch level {
        case .normal:
            .default
        case .warning:
            Self.takesWarningShare(traits) ? Self.warningShare.scaled(by: mode.share) : .default
        case .critical:
            .criticalThreshold
        }
    }

    /// Whether a consumer gives memory back at warning: managed, lossless, memory only and cheap.
    private static func takesWarningShare(_ traits: MemoryConsumerTraits) -> Bool {
        traits.isManaged && traits.retention == .lossless && traits.dataAccess == .none
            && traits.recreateCost == .cheap
    }
}
