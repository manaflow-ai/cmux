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

    /// Posted by ``TerminalSurface`` after its font-size lineage changes
    /// (runtime zoom, reset, or config reconciliation; `object`: the
    /// surface model).
    static let terminalSurfaceFontSizeLineageDidChange =
        Notification.Name("cmux.terminalSurfaceFontSizeLineageDidChange")
}
