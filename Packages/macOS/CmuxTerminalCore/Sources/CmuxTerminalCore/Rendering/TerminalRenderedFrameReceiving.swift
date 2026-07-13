/// The view-side receiver of rendered-frame instrumentation events.
///
/// Implemented by the app's terminal surface view so the engine's Metal layer
/// can report that a drawable was vended without importing the view layer.
/// The layer waits for drawable presentation, then hops to the main actor;
/// the receiver coalesces bursts into a single
/// notification per main-queue turn.
///
/// `Sendable` is required so the renderer-thread producer can carry the weak
/// reference into its main-actor hop; conformers are `@MainActor` classes,
/// which are implicitly `Sendable`, so the requirement costs them nothing.
@MainActor
public protocol TerminalRenderedFrameReceiving: AnyObject, Sendable {
    /// Schedules a coalesced presented-frame notification stamped at the renderer source.
    func enqueueRenderedFrameUpdate(generation: UInt64)
}
