public import Foundation

public extension Notification.Name {
    /// Posted by ``TerminalSurface`` after a runtime surface finishes
    /// creation (`userInfo`: `surfaceId`, `workspaceId`; `object`: the
    /// surface model).
    static let terminalSurfaceDidBecomeReady =
        Notification.Name("cmux.terminalSurfaceDidBecomeReady")

    /// Posted by ``TerminalSurface`` after a runtime clipboard read
    /// completes (`object`: the surface model).
    static let terminalSurfaceDidCompleteClipboardRead =
        Notification.Name("terminalSurfaceDidCompleteClipboardRead")
}
