/// The memory pressure level cmux votes into a pressure aggregator that already hears the kernel on
/// its own: in-process Chromium's `MultiSourceMemoryPressureMonitor`
/// (components/memory_pressure/multi_source_memory_pressure_monitor.h), whose macOS platform voter
/// (`SystemMemoryPressureEvaluatorMac`, started by content/browser/browser_main_loop.cc
/// `CreateMemoryPressureMonitor`) is the app's one accepted second pressure source (p07-memory DC2).
///
/// The aggregator takes the highest vote, so the vote carries only what that platform voter cannot
/// see: the memory coordinator's debug override (`debug.hibernation.pressure`). With no override the
/// vote is ``MemoryPressureLevel/normal``, which is no vote (Chromium's `MEMORY_PRESSURE_LEVEL_NONE`):
/// the kernel's level already reaches Chromium through its own voter, and voting it a second time
/// would run Chromium's pressure listeners twice per kernel event. A vote can raise Chromium's level
/// and hold it after a kernel normal event; it never lowers it.
///
/// ```swift
/// observation = coordinator.observePressureVote { [weak self] vote in self?.send(vote) }
/// send(coordinator.pressureVote)
/// ```
@MainActor
public protocol MemoryPressureVoteSource: AnyObject {
    /// The vote now; ``MemoryPressureLevel/normal`` is no vote.
    var pressureVote: MemoryPressureLevel { get }

    /// Calls `handler` on the main actor once per change of ``pressureVote``, in the turn of the change,
    /// until the returned registration is released or cancelled. A repeated vote makes no call.
    ///
    /// - Parameter handler: Main-actor work for each new vote.
    /// - Returns: The registration; keep it in a stored property.
    func observePressureVote(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel>
}
