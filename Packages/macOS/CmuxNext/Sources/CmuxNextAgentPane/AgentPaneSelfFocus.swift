public import AppKit
public import WebKit

/// An agent page cannot take the keyboard by itself (cx-3hw0i.2). A page's own `element.focus()`
/// (a subagent pane's composer as its page loads) makes WebKit ask the window to make its web
/// view first responder (`WebPageProxy::makeFirstResponder`). The app's focus model takes every
/// responder change as the user's choice, so a subagent pane that opened with `keep_focus` took
/// the keyboard and the daemon focus. The window refuses such a request outside an input event and
/// outside the focus model's own moves, for a page that is not in the focused pane or does not show;
/// a click or a key into the page, and the focus model's moves, still give it the keyboard.
extension AgentPaneView {
    /// Whether the window refuses to make `responder` first responder. `pane` names the pane that
    /// shows a view (nil when none does). `focusedPane` is read only for a page's own ask: the pane
    /// focus is on once the focus model's queued changes land, since the ask's report is reduced
    /// after them (a link's tab whose focus was still queued lost to the page it was clicked in).
    public static func refusesSelfFocus(_ responder: NSResponder?, inInputEvent: Bool, focusModelApplies: Bool,
                                        focusedPane: () -> String?, pane: (NSView) -> String?) -> Bool {
        // Only WebKit asks the window this way; a Chromium page takes the keyboard in its own child window.
        guard !inInputEvent, !focusModelApplies, let asking = responder as? WKWebView, showsPage(asking) else {
            return false
        }
        // A page that does not show never takes the keyboard by itself: a tab parked hidden behind the
        // focused pane's shown tab counts as that pane's content, so the focus model saw no change and
        // typing went into the hidden page (its composer mounting as a New Tab ask turned into the chat).
        // visibility-walk-allow: the responder change AppKit is asked for here reads AppKit's own view state, as a hit test does; once per page focus ask
        if asking.isHiddenOrHasHiddenAncestor { return true }
        guard let focusedPane = focusedPane(), let shown = pane(asking) else { return false }
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
