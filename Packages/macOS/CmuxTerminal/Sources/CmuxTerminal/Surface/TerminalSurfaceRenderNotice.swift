public import Foundation

/// Keys for the armed first-frame notice a workspace handoff subscribes to
/// (manaflow-ai/cmux#1291). Posted on the main actor after a surface with an
/// armed notice completes a renderer frame.
public enum TerminalSurfaceRenderNotice {
    /// `userInfo` key carrying the surface's stable `UUID`.
    public static let surfaceIdKey = "surfaceId"
}

extension Notification.Name {
    /// A surface with an armed frame notice completed a renderer frame.
    public static let terminalSurfaceDidRenderFrame =
        Notification.Name("cmux.terminalSurfaceDidRenderFrame")
}
