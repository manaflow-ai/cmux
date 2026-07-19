import Foundation
import CmuxTerminal

extension TerminalPanel {
    func performInternalBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performInternalBindingAction(action)
    }
}

extension GhosttyApp {
    func handleCurrentDirectoryAction(
        _ directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView
    ) {
        let terminalSurface = surfaceView.terminalSurface
        // A bounded per-surface AsyncStream drives one MainActor consumer.
        // Ordinary PWD actions coalesce; registered replay markers
        // remain ordered and cannot be displaced by terminal output floods.
        surfaceView.currentDirectoryActionDispatcher.enqueue(
            directory: directory,
            authoritativeGeometry: authoritativeGeometry,
            surfaceView: surfaceView,
            terminalSurface: terminalSurface
        )
    }
}

extension GhosttyNSView {
    func registerNotificationScrollReplayBoundaries(
        startBoundary: String,
        endBoundary: String
    ) {
        currentDirectoryActionDispatcher = GhosttyCurrentDirectoryActionDispatcher(
            startBoundary: startBoundary,
            endBoundary: endBoundary
        )
    }

    static func retainRenderedFrameNotifications() -> () -> Void {
        // See GhosttyApp.retainTickNotifications() on the idempotent release.
        let retention = GhosttyApp.renderedFrameNotificationDemand.retain()
        return { retention.release() }
    }

    @objc dynamic func readAuthoritativeScrollbar(
        _ result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        guard let surface = terminalSurface?.surface else { return false }
        return ghostty_surface_scrollbar(surface, result)
    }

    @objc dynamic func scrollToRow(
        _ row: UInt64,
        ifRowSpaceRevisionMatches rowSpaceRevision: UInt64,
        result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        guard let surface = terminalSurface?.surface else { return false }
        return ghostty_surface_scroll_to_row_if_revision(
            surface,
            row,
            rowSpaceRevision,
            result
        )
    }

}
