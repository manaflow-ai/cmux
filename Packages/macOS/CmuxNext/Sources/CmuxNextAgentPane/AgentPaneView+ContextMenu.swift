import AppKit
import CmuxNextActions
import WebKit

/// The agent pane's web view on the old host: WebKit's context menu goes through the pane
/// (``AgentPaneView/editContextMenu(_:)``). On the page host the shared view's
/// `contextMenuEditor` does the same.
final class AgentPaneWKWebView: WKWebView {
    var contextMenuEditor: (@MainActor (NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        contextMenuEditor?(menu)
        super.willOpenMenu(menu, with: event)
    }
}

/// Receives the page's report of the message under the pointer (`cmuxAgentContextMenu`), sent on
/// `contextmenu` before WebKit asks the host for the menu. Holds the view weakly (the user content
/// controller retains its handlers).
final class AgentPaneContextMenuReporter: NSObject, WKScriptMessageHandler {
    weak var view: AgentPaneView?

    init(view: AgentPaneView) {
        self.view = view
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view, message.webView === view.webView, message.frameInfo.isMainFrame else { return }
        view.receiveContextMenuReport(message.body)
    }
}

/// The target of a context-menu item that runs a closure; the item keeps it alive
/// (`representedObject`, since `target` is weak).
final class AgentPaneMenuAction: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    /// An item titled `title` that runs `handler`.
    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = AgentPaneMenuAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}

extension AgentPaneView {
    /// The page's message handler for ``AgentPaneContextMenuReporter``.
    static let contextMenuHandler = "cmuxAgentContextMenu"

    /// Routes WebKit's context menu through the pane and listens for the page's reports.
    func installContextMenu() {
        // A page host view can come back from its pool: never add the handler twice (WebKit throws).
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.contextMenuHandler, contentWorld: .page)
        webView.configuration.userContentController.add(AgentPaneContextMenuReporter(view: self), contentWorld: .page,
                                                        name: Self.contextMenuHandler)
        let edit: @MainActor (NSMenu) -> Void = { [weak self] menu in self?.editContextMenu(menu) }
        if let page { page.contextMenuEditor = edit } else { (webView as? AgentPaneWKWebView)?.contextMenuEditor = edit }
    }

    /// Undoes ``installContextMenu()`` when the pane closes.
    func removeContextMenu() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.contextMenuHandler, contentWorld: .page)
        page?.contextMenuEditor = nil
        (webView as? AgentPaneWKWebView)?.contextMenuEditor = nil
    }

    /// The page's report for the menu about to open (nil: the pointer is not on a message).
    func receiveContextMenuReport(_ body: Any?) {
        messageMenuTarget = AgentPaneMessageTarget(report: body)
    }

    /// Builds the pane's menu from WebKit's for the last report, which it uses up.
    func editContextMenu(_ menu: NSMenu) {
        let target = messageMenuTarget
        messageMenuTarget = nil
        AgentPaneContextMenu.rebuild(menu, target: target, devTools: DevTools.isEnabled, actions: .init(
            copy: { [weak self] text in self?.copyText(text) },
            fork: { [weak self] seq in self?.fork(through: seq) }))
    }

    /// Fork from Here: the turn footer's fork, through the page's own action. The menu choice is
    /// the user's gesture, as a native permission shortcut is.
    private func fork(through seq: Int) {
        model.transport.gestures.record()
        evaluateScript("window.cmuxAcpmuxActions?.['chat.fork']?.({ throughSeq: \(seq) });")
    }
}
