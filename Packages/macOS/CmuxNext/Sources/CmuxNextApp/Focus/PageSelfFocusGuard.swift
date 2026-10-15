import AppKit
import CmuxNextAgentPane
import WebKit

/// An agent page cannot take the keyboard by itself (cx-3hw0i.2): a page's own `element.focus()`
/// makes WebKit ask for first responder (`WebPageProxy::makeFirstResponder`), and the focus model
/// takes every responder change as the user's choice, so a subagent pane that opened with
/// `keep_focus` took the keyboard. Refused outside an input event and the model's own moves, for a
/// page outside the focused pane that no pending focus expectation names.
extension ShellWindow {
    func refusesPageSelfFocus(_ responder: NSResponder?) -> Bool {
        guard let webView = responder as? WKWebView, Self.agentPage(of: webView) != nil,
              (NSApp as? CmuxApplication)?.isHandlingSendEvent() != true,
              let controller = windowController as? WindowController, !controller.focus.isApplying,
              let focused = controller.focus.state.pane,
              case .content(let pane) = FocusResponderClassifier.classify(webView, in: controller) else { return false }
        return pane != focused && !Self.expects(pane, controller.focus.state)
    }

    /// Whether a pending focus expectation names a tab of `pane` (a person's move or open the
    /// page's tab is landing in); any other expectation, even one that never lands, does not.
    private static func expects(_ pane: String, _ state: FocusState) -> Bool {
        guard let expectation = state.expectation, let tabs = state.topology.panes.first(where: { $0.id == pane })?.tabs else { return false }
        return tabs.contains { tab in
            switch expectation.key {
            case .tab(let id): tab.id == id
            case .surface(let id): tab.surface == id
            }
        }
    }

    private static func agentPage(of view: NSView) -> AgentPaneView? {
        var current = view.superview
        while let next = current {
            if let page = next as? AgentPaneView { return page }
            current = next.superview
        }
        return nil
    }
}
