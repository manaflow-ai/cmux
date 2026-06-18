/// Schedules renderer-reclamation passes for the surface model.
///
/// Implemented by the app's `RendererRealizationController`; the surface
/// model kicks an immediate pass when a non-blocking realize enqueue drops so
/// the controller re-realizes the visible surface on the next runloop turn.
public protocol TerminalRendererRealizationScheduling: AnyObject, Sendable {
    /// Requests an immediate reclamation/realization pass.
    @MainActor
    func scheduleImmediatePass()
}
