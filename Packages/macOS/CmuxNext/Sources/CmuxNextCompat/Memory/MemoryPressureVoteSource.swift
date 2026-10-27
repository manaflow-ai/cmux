/// The memory pressure level cmux votes into a pressure aggregator that already hears the kernel on
/// its own: in-process Chromium's `MultiSourceMemoryPressureMonitor`
/// (components/memory_pressure/multi_source_memory_pressure_monitor.h), whose macOS platform voter
/// (`SystemMemoryPressureEvaluatorMac`, started by content/browser/browser_main_loop.cc
/// `CreateMemoryPressureMonitor`) is the app's one accepted second pressure source (p07-memory DC2).
///
/// The vote is the memory coordinator's level: its debug override (`debug.hibernation.pressure`)
/// when set, else the cmux level. ``MemoryPressureLevel/normal`` is Chromium's
/// `MEMORY_PRESSURE_LEVEL_NONE`. The aggregator takes the highest vote, so a vote can raise Chromium's
/// level and hold it after a kernel normal event; it never lowers it. Chromium's listeners run only
/// when the aggregate changes (the voter's `SetVote` is called with `notify_listeners` false), so a
/// kernel event that both voters report runs them once.
///
/// ```swift
/// observation = coordinator.observePressureVote { [weak self] vote in self?.send(vote) }
/// send(coordinator.pressureVote)
/// ```
@MainActor
public protocol MemoryPressureVoteSource: AnyObject {
    /// The vote now; ``MemoryPressureLevel/normal`` is Chromium's none.
    var pressureVote: MemoryPressureLevel { get }

    /// Calls `handler` on the main actor once per change of ``pressureVote``, in the turn of the change,
    /// until the returned registration is released or cancelled. A repeated vote makes no call.
    ///
    /// - Parameter handler: Main-actor work for each new vote.
    /// - Returns: The registration; keep it in a stored property.
    func observePressureVote(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel>
}
