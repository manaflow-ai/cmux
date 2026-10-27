/// The `memory.saver` setting: how hard cmux trims memory it can recreate, by Chrome's four Memory
/// Saver modes.
///
/// Each mode has a ``share`` of a managed consumer's full size, the values of Chrome's
/// `chrome/browser/performance_manager/policies/memory_saver_memory_coordinator_policy.h`
/// (off 100 %, conservative 75 %, medium 50 %, aggressive 25 %). The raw values are the setting's
/// spelling.
public enum MemorySaverMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// No Memory Saver scaling: managed consumers keep their full size.
    case off
    /// Managed consumers keep 75 % under pressure; discards wait longest.
    case conservative
    /// Managed consumers keep 50 % under pressure.
    case medium
    /// Managed consumers keep 25 % under pressure; discards come soonest.
    case aggressive

    /// The share of its full size a managed consumer keeps in this mode.
    public var share: MemoryLimit {
        switch self {
        case .off: MemoryLimit(percent: 100)
        case .conservative: MemoryLimit(percent: 75)
        case .medium: MemoryLimit(percent: 50)
        case .aggressive: MemoryLimit(percent: 25)
        }
    }

    /// How long hidden content of a kind that follows the mode waits before a proactive discard, as a
    /// multiple of that kind's own timeout; nil: no proactive discard at all (critical pressure still
    /// discards). Chrome's `chrome/browser/performance_manager/policies/memory_saver_mode_policy.cc`
    /// waits 6 h, 4 h and 2 h hidden in conservative, medium and aggressive, and discards nothing
    /// proactively with Memory Saver off. cmux keeps those ratios around each kind's shipped timeout,
    /// which is the medium one (a page tab's 10 minutes, a parked workspace's 15).
    public var proactiveTimeoutScale: Double? {
        switch self {
        case .off: nil
        case .conservative: 1.5
        case .medium: 1
        case .aggressive: 0.5
        }
    }

    /// `timeout` (a kind's medium timeout) in this mode; nil when the mode discards nothing proactively.
    ///
    /// - Parameter timeout: The kind's timeout at medium.
    /// - Returns: The time hidden before a proactive discard, or nil.
    public func proactiveTimeout(_ timeout: Duration) -> Duration? {
        proactiveTimeoutScale.map { timeout * $0 }
    }
}
