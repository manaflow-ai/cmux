import Foundation
import CmuxTerminal

private final class GhosttyCurrentDirectoryAction: @unchecked Sendable {
    let directory: String
    let authoritativeGeometry: NotificationScrollRestoreGeometry?
    weak var surfaceView: GhosttyNSView?
    weak var terminalSurface: TerminalSurface?

    init(
        directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView,
        terminalSurface: TerminalSurface?
    ) {
        self.directory = directory
        self.authoritativeGeometry = authoritativeGeometry
        self.surfaceView = surfaceView
        self.terminalSurface = terminalSurface
    }
}

private final class GhosttyCurrentDirectoryActionDispatcher: @unchecked Sendable {
    static let shared = GhosttyCurrentDirectoryActionDispatcher()

    private let continuation: AsyncStream<GhosttyCurrentDirectoryAction>.Continuation

    private init() {
        let (stream, continuation) = AsyncStream<GhosttyCurrentDirectoryAction>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        Task { @MainActor in
            for await action in stream {
                Self.deliver(action)
            }
        }
    }

    func enqueue(_ action: GhosttyCurrentDirectoryAction) {
        continuation.yield(action)
    }

    @MainActor
    private static func deliver(_ action: GhosttyCurrentDirectoryAction) {
        guard let surfaceView = action.surfaceView else { return }
        if action.terminalSurface?.hostedView.sessionScrollbackReplayDidReceiveBoundary(
            action.directory,
            authoritativeGeometry: action.authoritativeGeometry
        ) == true {
            return
        }
        guard let tabId = surfaceView.tabId,
              let surfaceId = action.terminalSurface?.id else { return }
        AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateReportedSurfaceDirectory(
            tabId: tabId,
            surfaceId: surfaceId,
            directory: action.directory
        )
    }
}

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
        // AsyncStream preserves Ghostty's PTY action order while a single
        // MainActor consumer handles UI state without blocking the callback.
        GhosttyCurrentDirectoryActionDispatcher.shared.enqueue(
            GhosttyCurrentDirectoryAction(
                directory: directory,
                authoritativeGeometry: authoritativeGeometry,
                surfaceView: surfaceView,
                terminalSurface: terminalSurface
            )
        )
    }
}

extension GhosttyNSView {
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
