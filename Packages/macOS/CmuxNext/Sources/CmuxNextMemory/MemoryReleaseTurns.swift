/// Where ``MemoryCoordinator`` runs its release slices while no cmux window is visible: on a later
/// main-queue turn, after the events already queued, with no frame to wait for.
///
/// A hidden app's frame scheduler ticks only on its stall deadline (one tick per 100 ms), so frame
/// slices of 2 ms would give a critical release 20 ms a second. With nothing on screen there is no
/// frame to protect: the coordinator takes 8 ms slices back to back on these turns instead, and goes
/// back to frames when a window shows or input arrives. Chromium does the same with its idle tasks:
/// with no frame expected the renderer's scheduler runs long idle periods of up to 50 ms instead of
/// the gap before the next frame (`third_party/blink/renderer/platform/scheduler/common/idle_helper.cc`,
/// `kMaximumIdlePeriod`).
///
/// The app passes an adapter made at the composition root; a test passes a fake whose turns it runs.
///
/// ```swift
/// turns.scheduleTurn { [weak self] in self?.turnDidCome() }
/// ```
@MainActor
public protocol MemoryReleaseTurns: AnyObject {
    /// Calls `turn` once on the main actor on a later main-queue turn, after the work already queued
    /// there (input first). Never calls it before returning.
    ///
    /// The coordinator has at most one turn asked for at a time.
    ///
    /// - Parameter turn: One release slice.
    func scheduleTurn(_ turn: @escaping @MainActor () -> Void)
}
