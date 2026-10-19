import AppKit
import CmuxNextActions
import CmuxNextPages
import WebKit

/// The agent pane's web view on the old host: WebKit's context menu goes through the pane
/// (``AgentPaneView/editContextMenu(_:)``). On the page host the shared view's
/// `contextMenuEditor` does the same.
final class AgentPaneWKWebView: WKWebView {
    var contextMenuEditor: (@MainActor (NSMenu) -> Void)?
    /// Files the person dropped on the page: a real gesture page script can't make (``AgentPaneUpload``).
    var onFilesDropped: (@MainActor () -> Void)?

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { onFilesDropped?() }
        return super.performDragOperation(sender)
    }

    /// Keeps macOS's AutoFill out of this view's context menu (``PageMenuAutoFill``).
    private let menuAutoFill = PageMenuAutoFill()

    override var inputContext: NSTextInputContext? {
        menuAutoFill.hidesInputContext() ? nil : super.inputContext
    }

    override func mouseDown(with event: NSEvent) {
        menuAutoFill.noteContextClick(event)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        menuAutoFill.noteContextClick(event)
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menuAutoFill.menuWillOpen()
        contextMenuEditor?(menu)
        super.willOpenMenu(menu, with: event)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        menuAutoFill.menuDidClose()
        super.didCloseMenu(menu, with: event)
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

    /// Routes WebKit's context menu through the pane and listens for the page's reports. Also takes
    /// a native file drop on the page as the person's gesture (an upload's, ``AgentPaneUpload``).
    func installContextMenu() {
        let dropped: @MainActor () -> Void = { [weak self] in self.map { AgentPanePersonInput.record($0.model.transport.gestures) } }
        if let page { page.onFilesDropped = dropped } else { (webView as? AgentPaneWKWebView)?.onFilesDropped = dropped }
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
        page?.onFilesDropped = nil
        (webView as? AgentPaneWKWebView)?.contextMenuEditor = nil
        (webView as? AgentPaneWKWebView)?.onFilesDropped = nil
    }

    /// The page's report for the menu about to open (nil: the pointer is not on a message).
    func receiveContextMenuReport(_ body: Any?) {
        messageMenuTarget = AgentPaneMessageTarget(report: body)
        menuSelection = AgentPaneContextMenu.selection(report: body)
    }

    /// Builds the pane's menu from WebKit's for the last report, which it uses up.
    func editContextMenu(_ menu: NSMenu) {
        let target = messageMenuTarget, selection = menuSelection
        messageMenuTarget = nil
        menuSelection = nil
        let chatMenu = target == nil && selection == nil ? model.chatMenuItems?() ?? [] : []
        AgentPaneContextMenu.rebuild(menu, target: target, selection: selection, devTools: DevTools.isEnabled, chatMenu: chatMenu, actions: .init(
            copy: { [weak self] text in self?.copyText(text) },
            fork: { [weak self] seq in self?.fork(through: seq) },
            retry: { [weak self] row in self?.runMessageAction("chat.retryPrompt", ["rowId": row]) },
            edit: { [weak self] text in self?.runMessageAction("chat.editPrompt", ["text": text]) },
            editPrompt: { [weak self] text, row in
                self?.runMessageAction("chat.editPrompt", row.map { ["text": text, "rowId": $0] } ?? ["text": text])
            },
            open: { [weak self] url in self?.openLink(url) },
            linkItems: { LinkMenu().linkItems(for: $0) },
            pathItems: { [weak self] path in self?.pathMenuItems(path) },
            search: { [weak self] text in self?.model.onSearchWeb?(text) },
            page: { [weak self] name, params in self?.runMessageAction(name, params) }))
    }

    /// Retry, Edit and Resend, Open Image and a path's Open: the page's own actions, with the menu choice as the gesture.
    private func runMessageAction(_ name: String, _ params: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return }
        AgentPanePersonInput.record(model.transport.gestures)
        evaluateScript("window.cmuxAcpmuxActions?.['\(name)']?.(\(String(decoding: data, as: UTF8.self)));")
    }

    /// Open Link: outside the pane, on the rule a click on the link follows.
    private func openLink(_ url: URL) {
        AgentPanePersonInput.record(model.transport.gestures)
        _ = AgentPaneNavigation.openOutside(url, gestures: model.transport.gestures) { self.openURL($0, false) }
    }

    /// Fork from Here: the turn footer's fork, through the page's own action. The menu choice is
    /// the user's gesture, as a native permission shortcut is.
    private func fork(through seq: Int) {
        AgentPanePersonInput.record(model.transport.gestures)
        evaluateScript("window.cmuxAcpmuxActions?.['chat.fork']?.({ throughSeq: \(seq) });")
    }
}
