/// Where ``MemoryCoordinator`` runs its release slices: on the next frame, never in the turn that
/// asks.
///
/// The app passes an adapter over its frame scheduler (a `FrameClient` that ticks once), made at the
/// composition root; a test passes a fake whose frames it fires. The next frame is a later turn than
/// the pressure event, so the coordinator's slices never share a turn with the listeners in-process
/// Chromium runs on the main thread for the same event (p07-memory.md risk 6).
///
/// ```swift
/// slicer.scheduleSlice { [weak self] in self?.runSlice() }
/// ```
@MainActor
public protocol MemoryReleaseSlicer: AnyObject {
    /// Calls `slice` once on the main actor on the next frame. Never calls it before returning.
    ///
    /// The coordinator asks at most once per frame.
    ///
    /// - Parameter slice: One release slice.
    func scheduleSlice(_ slice: @escaping @MainActor () -> Void)
}
