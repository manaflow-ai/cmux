import AppKit
import CmuxNextDesign

/// The window's share of in-tree pages (`InTreePages`): the page focus rule of its one responder gate, and the keyboard
/// of an overlay that sits on the window itself instead of its panel.
extension ShellWindow {
    /// Whether the gate refuses making `responder`, a view of an in-tree Chromium page, the first responder: the page
    /// takes the keys only for the person's input aimed at it, a focus-model move to its pane, a routed move naming
    /// it (`routeTarget`), cmux's own grant (`InTreePageFocus.granting`), or a move inside the page that already has the
    /// keyboard (Chromium's focus restore to its new view). Chromium focusing a page that does not have the keyboard,
    /// `CefBrowserHost::SetFocus` outside a grant and a page's `window.focus()` are refused. False for every other
    /// responder and with the mode off.
    func refusesInTreePage(_ responder: NSResponder?, routeTarget: NSResponder?) -> Bool {
        guard InTreePages.shared.isActive, responder is NSView else { return false }
        let controller = windowController as? WindowController
        let event = (NSApp as? CmuxApplication)?.isHandlingSendEvent() == true ? controller?.services.inputDispatch.event : nil
        return InTreePageFocus.shared.refuses(responder, in: self, event: event, focusModelApplies: focus?.isApplying == true,
                                               focusedPane: { controller?.focus.currentState().pane },
                                               paneOf: { controller?.inTreePagePane(of: $0) }, routeTarget: routeTarget)
    }

    /// Tab in an in-window modal overlay moves inside it (its panel's key view loop did).
    override func selectNextKeyView(_ sender: Any?) {
        if WindowOverlayHost.cycleInWindowModal(of: self, forward: true) { return }
        super.selectNextKeyView(sender)
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        if WindowOverlayHost.cycleInWindowModal(of: self, forward: false) { return }
        super.selectPreviousKeyView(sender)
    }
}

extension WindowController {
    /// The cmux pane an in-tree page container shows in: the pane whose view holds it, as `FocusResponderClassifier`
    /// classifies every responder (nil when it is in no pane). The browser cannot say: it knows its own tab key
    /// (`tab-…`), never the pane (`pane_…`), and a tab moves between panes.
    func inTreePagePane(of view: NSView) -> String? {
        guard let panes = content?.panes.values else { return nil }
        return panes.first { view.isDescendant(of: $0.view) }?.paneKey
    }
}
