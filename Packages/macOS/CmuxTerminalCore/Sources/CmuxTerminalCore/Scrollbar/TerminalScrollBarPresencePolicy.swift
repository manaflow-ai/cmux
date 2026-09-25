/// Decides whether a terminal pane's vertical scroller is present.
///
/// Presence is a layout input, not only a visual: with the legacy scroller
/// style the terminal grid loses the columns under the gutter. Under that
/// style presence must not follow the surface's own scrollback, or the grid
/// becomes a function of the terminal's content. A local pane then reflows
/// when its first row scrolls off (https://github.com/manaflow-ai/cmux/issues/3051),
/// and a Cloud mirror, whose reset empties history before every remote replay
/// refills it, reports a new grid after each replay; the remote PTY resizes
/// again and sends the next replay, and the loop never ends
/// (https://github.com/manaflow-ai/cmux/issues/12885).
///
/// An overlay scroller reserves nothing, so it stays hidden while nothing can
/// scroll and never sits on top of the rightmost column of a full-screen app.
public struct TerminalScrollBarPresencePolicy: Sendable {
    private let allowedBySettings: Bool
    private let scrollerStyle: TerminalScrollerStyle
    private let hasScrollback: Bool?

    /// Creates a snapshot of the scrollbar layout inputs.
    ///
    /// - Parameters:
    ///   - allowedBySettings: Whether the Ghostty `scrollbar` config and the
    ///     cmux scroll bar preference permit a scroller at all.
    ///   - scrollerStyle: How the host's scroller participates in layout.
    ///   - hasScrollback: Whether the surface has rows above its viewport, or
    ///     nil while the runtime has not published its first scrollbar state.
    public init(
        allowedBySettings: Bool,
        scrollerStyle: TerminalScrollerStyle,
        hasScrollback: Bool?
    ) {
        self.allowedBySettings = allowedBySettings
        self.scrollerStyle = scrollerStyle
        self.hasScrollback = hasScrollback
    }

    /// Whether the snapshot requires a scroller.
    public var isPresent: Bool {
        guard allowedBySettings else { return false }
        // A legacy scroller is part of the layout; keep it so the grid width
        // is the same with and without history.
        if scrollerStyle == .legacy { return true }
        // The runtime reports scrollback asynchronously. Until the first
        // packet arrives, keep the scroller so restored or reattached
        // surfaces with existing scrollback do not appear broken.
        return hasScrollback ?? true
    }
}
