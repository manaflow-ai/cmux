public import AppKit

/// The callbacks the canvas needs from its owning host (the workspace).
@MainActor
public struct CanvasHostCallbacks {
    public let onFocusPanel: (UUID) -> Void
    public let onClosePanel: (UUID) -> Void
    public let onLayoutChanged: () -> Void
    /// Fired (coalesced by the host) whenever on-screen pane geometry may
    /// have changed: scrolls, zooms, pane drags, document re-sizing. Hosts
    /// that overlay window-level content on panes (web view portals) re-sync
    /// from this.
    public let onViewportGeometryChanged: (NSWindow?) -> Void
    /// Fired once when a live scroll or magnify gesture ends, so hosts can
    /// run a heavier settle-up pass (forced portal refresh) than the
    /// per-frame geometry callback.
    public let onViewportSettled: (NSWindow?) -> Void

    public init(
        onFocusPanel: @escaping (UUID) -> Void,
        onClosePanel: @escaping (UUID) -> Void,
        onLayoutChanged: @escaping () -> Void,
        onViewportGeometryChanged: @escaping (NSWindow?) -> Void = { _ in },
        onViewportSettled: @escaping (NSWindow?) -> Void = { _ in }
    ) {
        self.onFocusPanel = onFocusPanel
        self.onClosePanel = onClosePanel
        self.onLayoutChanged = onLayoutChanged
        self.onViewportGeometryChanged = onViewportGeometryChanged
        self.onViewportSettled = onViewportSettled
    }
}
