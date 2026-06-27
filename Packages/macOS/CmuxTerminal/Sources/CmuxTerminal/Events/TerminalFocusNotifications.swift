public import Foundation

/// The legacy `ghostty*` surface focus and title event names, re-homed from the
/// `TabManager.swift` god file as a byte-identical leaf move.
///
/// These `Notification.Name`s are posted by the embedded-Ghostty surface stack
/// (`GhosttyTerminalView`, `WindowToolbarController`) and observed across the
/// terminal, window-chrome, workspace, and mobile surfaces to drive tab/surface
/// focus and title updates. The post and observe sites still live in the app
/// target and reach these names through `import CmuxTerminal`; their raw
/// `Notification.Name(...)` payloads are unchanged so every existing
/// `NotificationCenter` post/observe keeps wire compatibility.
///
/// This mirrors ``ghosttyDidTick`` and the rest of the raw runtime bus already
/// re-homed in `TerminalRuntimeNotifications.swift`. The plan retires these raw
/// names in favour of typed focus/title observers backed by `AsyncStream`; that
/// conversion is deferred to a dedicated modernization slice because the
/// post/observe sites span surface and window-chrome code that moves in later
/// waves.
public extension Notification.Name {
    /// Posted after a Ghostty surface reports a new title (`userInfo` carries
    /// the title and originating surface).
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")

    /// Posted when a tab gains focus and the active surface should follow.
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")

    /// Posted when a Ghostty surface becomes the focused surface.
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")

    /// Posted when a Ghostty surface becomes first responder.
    static let ghosttyDidBecomeFirstResponderSurface = Notification.Name("ghosttyDidBecomeFirstResponderSurface")
}
