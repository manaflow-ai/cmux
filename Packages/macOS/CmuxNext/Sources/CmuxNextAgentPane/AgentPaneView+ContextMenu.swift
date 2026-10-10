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
        contextMenuController.install()
    }

    /// Undoes ``installContextMenu()`` when the pane closes.
    func removeContextMenu() {
        contextMenuController.remove()
    }

    /// The page's report for the menu about to open (nil: the pointer is not on a message).
    func receiveContextMenuReport(_ body: Any?) {
        contextMenuController.receive(report: body)
    }
}
