import CmuxTerminal

/// One copied PWD action crossing from Ghostty's PTY callback to the main actor.
/// SAFETY: construction fixes every strong field. The weak AppKit references
/// are only dereferenced by the dispatcher's main-actor delivery method.
final class GhosttyCurrentDirectoryAction: @unchecked Sendable {
    let directory: String
    let authoritativeGeometry: NotificationScrollRestoreGeometry?
    let replayBoundaryGeneration: UInt64?
    weak var surfaceView: GhosttyNSView?
    weak var terminalSurface: TerminalSurface?

    init(
        directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        replayBoundaryGeneration: UInt64?,
        surfaceView: GhosttyNSView,
        terminalSurface: TerminalSurface?
    ) {
        self.directory = directory
        self.authoritativeGeometry = authoritativeGeometry
        self.replayBoundaryGeneration = replayBoundaryGeneration
        self.surfaceView = surfaceView
        self.terminalSurface = terminalSurface
    }
}
