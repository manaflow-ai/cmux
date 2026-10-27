/// A ``MemoryConsumer`` whose proactive discards wait by the Memory Saver mode (`memory.saver`), such
/// as a discard planner of hidden content: the registry hands it the mode, not only the limits.
///
/// Chrome's `MemorySaverModePolicy` (chrome/browser/performance_manager/policies/memory_saver_mode_policy.cc)
/// reads the mode for its per-tab discard timers; the limits of
/// `memory_saver_memory_coordinator_policy.h` scale caches. A planner needs the first: the mode
/// changes when its hidden content is due (``MemorySaverMode/proactiveTimeout(_:)``). It gets the
/// mode from its registration, never from a second follower of the setting.
///
/// The registry calls ``memorySaverModeDidChange(_:)`` with the current mode before the
/// registration's init returns, then on each change of mode, after the new limits.
@MainActor
public protocol MemorySaverModeConsumer: MemoryConsumer {
    /// Takes the mode the registry acts on now.
    ///
    /// - Parameter mode: The `memory.saver` mode.
    func memorySaverModeDidChange(_ mode: MemorySaverMode)
}
