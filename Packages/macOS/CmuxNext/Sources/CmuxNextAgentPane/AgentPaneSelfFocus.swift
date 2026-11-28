public import AppKit
public import WebKit

/// An agent page cannot take the keyboard by itself (cx-3hw0i.2). A page's own `element.focus()`
/// (a subagent pane's composer as its page loads) makes WebKit ask the window to make its web
/// view first responder (`WebPageProxy::makeFirstResponder`). The app's focus model takes every
/// responder change as the user's choice, so a subagent pane that opened with `keep_focus` took
/// the keyboard and the daemon focus. The window refuses such a request outside an input event and
/// outside the focus model's own moves, for a page that is not in the focused pane; a click or a
/// key into the page, and the focus model's moves, still give it the keyboard.
extension AgentPaneView {
    /// Whether the window refuses to make `responder` first responder. `pane` names the pane that
    /// shows a view (nil when none does).
    public static func refusesSelfFocus(_ responder: NSResponder?, inInputEvent: Bool, focusModelApplies: Bool,
                                        focusedPane: String?, pane: (NSView) -> String?) -> Bool {
        guard !inInputEvent, !focusModelApplies, let focusedPane, let webView = responder as? WKWebView,
              showsPage(webView), let shown = pane(webView) else { return false }
        return shown != focusedPane
    }

    private static func showsPage(_ view: NSView) -> Bool {
        var current = view.superview
        while let next = current {
            if next is AgentPaneView { return true }
            current = next.superview
        }
        return false
    }
}
