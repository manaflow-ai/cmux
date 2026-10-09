import AppKit
import CmuxNextActions
import Foundation
import WebKit

/// Owns the WebKit context-menu bridge for an agent pane. Keeping the bridge's transient report
/// and page actions together leaves ``AgentPaneView`` responsible only for installing its owner.
@MainActor
final class AgentPaneContextMenuController {
    weak var view: AgentPaneView?
    private var messageMenuTarget: AgentPaneMessageTarget?
    private var menuSelection: String?

    init(view: AgentPaneView) {
        self.view = view
    }

    func install() {
        guard let view else { return }
        // A page host view can come back from its pool: never add the handler twice (WebKit throws).
        view.webView.configuration.userContentController.removeScriptMessageHandler(
            forName: AgentPaneView.contextMenuHandler, contentWorld: .page)
        view.webView.configuration.userContentController.add(
            AgentPaneContextMenuReporter(view: view), contentWorld: .page,
            name: AgentPaneView.contextMenuHandler)
        let edit: @MainActor (NSMenu) -> Void = { [weak self] menu in self?.edit(menu) }
        if let page = view.page {
            page.contextMenuEditor = edit
        } else {
            (view.webView as? AgentPaneWKWebView)?.contextMenuEditor = edit
        }
    }

    func remove() {
        guard let view else { return }
        view.webView.configuration.userContentController.removeScriptMessageHandler(
            forName: AgentPaneView.contextMenuHandler, contentWorld: .page)
        view.page?.contextMenuEditor = nil
        (view.webView as? AgentPaneWKWebView)?.contextMenuEditor = nil
    }

    func receive(report body: Any?) {
        messageMenuTarget = AgentPaneMessageTarget(report: body)
        menuSelection = AgentPaneContextMenu.selection(report: body)
    }

    /// Builds the pane's menu from WebKit's for the last report, which it uses up.
    private func edit(_ menu: NSMenu) {
        guard let view else { return }
        let target = messageMenuTarget, selection = menuSelection
        messageMenuTarget = nil
        menuSelection = nil
        let chatMenu = target == nil && selection == nil ? view.model.chatMenuItems?() ?? [] : []
        AgentPaneContextMenu.rebuild(menu, target: target, selection: selection, devTools: DevTools.isEnabled,
                                     chatMenu: chatMenu, actions: .init(
            copy: { [weak view] text in view?.copyText(text) },
            fork: { [weak self] seq in self?.fork(through: seq) },
            retry: { [weak self] row in self?.runMessageAction("chat.retryPrompt", ["rowId": row]) },
            edit: { [weak self] text in self?.runMessageAction("chat.editPrompt", ["text": text]) },
            open: { [weak self] url in self?.openLink(url) },
            search: { [weak view] text in view?.model.onSearchWeb?(text) },
            openImage: { [weak self] in self?.runMessageAction("chat.menu.openImage", [:]) }))
    }

    /// Retry, Edit and Resend, and Open Image: the page's own actions, with the menu choice as the gesture.
    private func runMessageAction(_ name: String, _ params: [String: String]) {
        guard let view, let data = try? JSONSerialization.data(withJSONObject: params) else { return }
        view.model.transport.gestures.record()
        view.evaluateScript("window.cmuxAcpmuxActions?.['\(name)']?.(\(String(decoding: data, as: UTF8.self)));" )
    }

    /// Open Link: outside the pane, on the rule a click on the link follows.
    private func openLink(_ url: URL) {
        guard let view else { return }
        view.model.transport.gestures.record()
        _ = AgentPaneNavigation.openOutside(url, gestures: view.model.transport.gestures, open: view.openURL)
    }

    /// Fork from Here: the turn footer's fork, through the page's own action. The menu choice is
    /// the user's gesture, as a native permission shortcut is.
    private func fork(through seq: Int) {
        guard let view else { return }
        view.model.transport.gestures.record()
        view.evaluateScript("window.cmuxAcpmuxActions?.['chat.fork']?.({ throughSeq: \(seq) });")
    }
}
