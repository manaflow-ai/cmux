import AppKit
import CmuxNextAgentPane
import WebKit

/// An agent page cannot take the keyboard by itself (cx-3hw0i.2). A page's own `element.focus()`
/// (a subagent pane's composer as its page loads) makes WebKit ask the window to make its web
/// view first responder (`WebPageProxy::makeFirstResponder`). The focus model accepts every
/// responder change as the user's choice, so a pane that opened beside the chat took the keyboard
/// and the daemon focus, although its move ran with `keep_focus`. Such a request is refused when
/// no input event is in dispatch, the focus model is not applying its own target, and the page is
/// in another pane than the focused one with no focus expectation pending (a New Tab page this
/// window opened lands its expectation first); a click or a key into the page, and the focus model's
/// own moves, still give it the keyboard.
extension ShellWindow {
    func refusesPageSelfFocus(_ responder: NSResponder?) -> Bool {
        guard let webView = responder as? WKWebView, Self.agentPage(of: webView) != nil,
              (NSApp as? CmuxApplication)?.isHandlingSendEvent() != true,
              let controller = windowController as? WindowController, !controller.focus.isApplying,
              controller.focus.state.expectation == nil,
              let focused = controller.focus.state.pane,
              case .content(let pane) = FocusResponderClassifier.classify(webView, in: controller) else { return false }
        return pane != focused
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
