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
}
