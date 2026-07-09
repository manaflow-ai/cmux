public import Foundation

/// The legacy `ghostty*` runtime event bus, re-homed from the
/// `GhosttyTerminalView.swift` god file as a byte-identical leaf move.
///
/// These `Notification.Name`s are posted by the embedded-Ghostty runtime and
/// the AppKit surface view stack (`GhosttyNSView`, `GhosttySurfaceScrollView`)
/// and observed across the terminal, browser, find, and mobile surfaces. The
/// post and observe sites still live in the app target and reach these names
/// through `import CmuxTerminal`; their raw `Notification.Name(...)` payloads
/// are unchanged so every existing `NotificationCenter` post/observe keeps wire
/// compatibility.
///
/// This is a deliberate first stage. The plan retires this raw bus in favour of
/// the typed ``TerminalScrollbarObserving`` / ``TerminalRenderObserving``
/// observer protocols (`CmuxTerminalCore`) backed by `AsyncStream`. That
/// conversion is deferred to a dedicated modernization slice, because the
/// post/observe sites span `GhosttyNSView` and `GhosttySurfaceScrollView`, which
/// move into `CmuxTerminalSurface` in later waves; converting now would split a
/// single event seam across moved and unmoved code.
public extension Notification.Name {
    /// Posted after the embedded Ghostty runtime advances one render tick.
    static let ghosttyDidTick = Notification.Name("ghosttyDidTick")

    /// Posted after the runtime finishes rendering a frame.
    static let ghosttyDidRenderFrame = Notification.Name("ghosttyDidRenderFrame")

    /// Posted after the surface scrollbar metrics change.
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")

    /// Posted after the terminal cell size changes (font/zoom/reflow).
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")

    /// Posted when a wheel-scroll gesture reaches the surface view.
    static let ghosttyDidReceiveWheelScroll = Notification.Name("ghosttyDidReceiveWheelScroll")

    /// Posted to request focus of the terminal find/search field.
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")

    /// Posted after the Ghostty configuration reloads.
    static let ghosttyConfigDidReload = Notification.Name("ghosttyConfigDidReload")

    /// Posted when the runtime default background color changes.
    static let ghosttyDefaultBackgroundDidChange = Notification.Name("ghosttyDefaultBackgroundDidChange")

    /// Posted to request focus of the browser find/search field.
    static let browserSearchFocus = Notification.Name("browserSearchFocus")
}
