import AppKit

/// Decides whether a terminal pane's vertical scroller is present.
///
/// Presence is a layout input, not only a visual: with the legacy scroller
/// style AppKit reserves a gutter for a present scroller, and the terminal
/// grid loses the columns underneath it. Under that style presence must not
/// follow the surface's own scrollback, or the grid becomes a function of the
/// terminal's content. A local pane then reflows when its first row scrolls
/// off (https://github.com/manaflow-ai/cmux/issues/3051), and a Cloud mirror,
/// whose reset empties history before every remote replay refills it, reports
/// a new grid after each replay; the remote PTY resizes again and sends the
/// next replay, and the loop never ends
/// (https://github.com/manaflow-ai/cmux/issues/12885).
///
/// An overlay scroller reserves nothing, so it stays hidden while nothing can
/// scroll and never sits on top of the rightmost column of a full-screen app.
enum TerminalScrollBarPresencePolicy {
    /// - Parameters:
    ///   - allowedBySettings: Whether the Ghostty `scrollbar` config and the
    ///     cmux scroll bar preference permit a scroller at all.
    ///   - scrollerStyle: The style the scroll view lays out with.
    ///   - hasScrollback: Whether the surface has rows above its viewport, or
    ///     nil while Ghostty has not published its first scrollbar state.
    static func isPresent(
        allowedBySettings: Bool,
        scrollerStyle: NSScroller.Style,
        hasScrollback: Bool?
    ) -> Bool {
        guard allowedBySettings else { return false }
        // A legacy scroller is part of the layout; keep it so the grid width
        // is the same with and without history.
        if scrollerStyle == .legacy { return true }
        // Ghostty reports scrollback asynchronously. Until the first packet
        // arrives, keep the scroller so restored or reattached surfaces with
        // existing scrollback do not appear broken.
        return hasScrollback ?? true
    }
}
