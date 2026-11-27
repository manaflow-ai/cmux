/// The view-side receiver of rendered-frame instrumentation events.
///
/// Implemented by the app's terminal surface view so the engine's Metal layer
/// can report that a drawable was vended without importing the view layer.
/// The layer hops to the main actor before calling; the receiver coalesces
/// bursts and performs only the requested surface-scoped work.
///
/// `Sendable` is required so the renderer-thread producer can carry the weak
/// reference into its main-actor hop; conformers are `@MainActor` classes,
/// which are implicitly `Sendable`, so the requirement costs them nothing.
@MainActor
public protocol TerminalRenderedFrameReceiving: AnyObject, Sendable {
    /// Schedules coalesced work for the supplied frame-delivery reasons.
    ///
    /// - Parameter reasons: Surface-scoped work that currently has demand.
    func enqueueRenderedFrameUpdate(
        reasons: TerminalRenderedFrameDeliveryReasons
    )
}
