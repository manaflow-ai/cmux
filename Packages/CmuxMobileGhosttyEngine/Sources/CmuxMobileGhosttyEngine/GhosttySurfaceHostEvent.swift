public import Foundation

/// Everything a hosting view needs to react to for one terminal surface,
/// delivered on a single ordered `AsyncStream` so the host runs exactly one
/// main-actor consumer task.
///
/// Producers:
/// - ``GhosttySurfaceSession`` emits ``outputApplied(accessibilityText:)``,
///   ``renderCompleted`` and ``geometryMeasured(_:)`` from its serial
///   executor as each command completes.
/// - The C-callback bridge emits ``outboundBytes(_:)`` and
///   ``closeRequested(processAlive:)`` straight from libghostty threads
///   (`AsyncStream.Continuation` is thread-safe; this is the sanctioned
///   C-ABI bridge into the async world).
/// - ``GhosttySurfaceRegistry`` emits ``focusInputRequested``,
///   ``titleChanged(_:)`` and ``bellRang`` when routing app-level actions.
public enum GhosttySurfaceHostEvent: Sendable {
    /// A submitted output chunk finished `ghostty_surface_process_output`.
    /// `accessibilityText` carries a throttled DEBUG read of the rendered
    /// surface text (always `nil` in release builds).
    case outputApplied(accessibilityText: String?)
    /// A `ghostty_surface_render_now` pass finished.
    case renderCompleted
    /// A geometry pass finished; apply the measurement to the host layer.
    case geometryMeasured(GhosttySurfaceGeometryMeasurement)
    /// libghostty wrote bytes toward the PTY (display-only mirrors drop them).
    case outboundBytes(Data)
    /// libghostty asked to close the surface.
    case closeRequested(processAlive: Bool)
    /// The app asked the surface to present the on-screen keyboard.
    case focusInputRequested
    /// The surface title changed.
    case titleChanged(String)
    /// The surface rang the bell.
    case bellRang
}
