public import Foundation

/// The simplified, user-visible outcome of a terminal drag-and-drop.
///
/// `GhosttyNSView`'s `NSDraggingDestination` handling produces a rich
/// app-side `TerminalImageTransferPlan` (carrying inter-segment delays and
/// upload targets). The test-only `GhosttyNSView.dropPlanForTesting` forwarder
/// collapses that into this three-way value so the drop regression tests can
/// assert the effect (text inserted, files uploaded, or nothing) without
/// reaching into the AppKit drag pipeline.
public enum TerminalDropPlan: Sendable, Equatable {
    /// Text to insert into the terminal at the drop point.
    case insertText(String)
    /// Local file URLs to upload to the (remote) terminal surface.
    case uploadFiles([URL])
    /// The drop is refused; nothing is inserted or uploaded.
    case reject
}
