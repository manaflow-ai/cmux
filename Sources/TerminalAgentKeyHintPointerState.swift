import AppKit
import CmuxTerminalCore

/// Per-view pointer state for clickable agent key hints (`agentActions.keyHints`).
@MainActor
final class TerminalAgentKeyHintPointerState {
    /// Cancellable timing source for the double-click deadline.
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    /// The cell a single left click pressed, while the setting is on.
    var pressCell: TerminalAgentKeyHintCell?
    /// A released click waiting out the double-click interval.
    var deferredPress: AgentKeyHintDeferredPress
    /// Re-resolves the original cell and authorization immediately before
    /// sending input. Invalidations clear this closure.
    var pendingPress: (() -> Void)?
    var deferredPressTask: Task<Void, Never>?
    var deferredPressTaskSequence: UInt64 = 0
    let deferredPressSleep: Sleep
    /// The cell hover last resolved; hover resolves again only when it changes.
    var hoverCell: TerminalAgentKeyHintCell?
    /// The hint under the pointer: its row and cells.
    var hoveredHint: (row: Int, columns: Range<Int>)?
    /// The viewport the hovered hint was read from.
    var hoveredViewport: TerminalAgentKeyHintViewportState?
    var underlineView: GhosttyFlashOverlayView?
    var toolTipTag: NSView.ToolTipTag?
    /// Tooltip owners are not retained by AppKit.
    var toolTipText: NSString?
    /// Reused at-rest marker overlays, one per detected span.
    var restMarkerViews: [GhosttyFlashOverlayView] = []
    var restViewport: TerminalAgentKeyHintViewportState?
    var restRowsHash: UInt64?

    init(
        delay: TimeInterval = NSEvent.doubleClickInterval,
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        deferredPress = AgentKeyHintDeferredPress(delay: delay)
        deferredPressSleep = sleep
    }

    func cancelDeferredPressTask() {
        deferredPressTaskSequence &+= 1
        deferredPressTask?.cancel()
        deferredPressTask = nil
    }
}
