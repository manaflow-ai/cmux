import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages
public import Foundation
import WebKit

public extension Notification.Name {
    /// Posted by an app-owned webview context menu while the Labs pointer inspector is enabled.
    static let cmuxNextInspectUIElement = Notification.Name("cmux.next.inspect-ui-element")
}

/// The target of a context-menu item that runs a closure; the item keeps it alive
/// (`representedObject`, since `target` is weak).
final class AgentPaneMenuAction: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    /// An item titled `title` with SF Symbol `symbol` (the matching action's catalog symbol: every
    /// cmux menu row shows one) that runs `handler`.
    static func item(_ title: String, symbol: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = AgentPaneMenuAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.image = AgentPaneContextMenu.icon(symbol)
        return item
    }
}

extension AgentPaneView {
    /// The page's message handler for its report of the message under the pointer
    /// (`cmuxAgentContextMenu`), sent on `contextmenu` before the engine asks the host for the menu.
    public static let contextMenuHandler = "cmuxAgentContextMenu"

    /// Routes WebKit's context menu through the pane and listens for the page's reports. Also takes
    /// a native file drop on the page as the person's gesture (an upload's, ``AgentPaneUpload``), and
    /// records where the files of the person's drop or paste are, for the page's
    /// `chat.attach.dropped` (``AgentPaneDroppedPaths``).
    func installContextMenu() {
        // A drop runs outside any dispatch: the drag's own end decides whether it is the person's.
        let dropped: @MainActor ([URL]) -> Void = { [weak self] urls in
            guard let self, dragEnd().isPersons else { return }
            model.transport.gestures.record()
            model.droppedPaths.stash(urls, kind: .drop)
        }
        // Read as the paste goes to WebKit: the pasteboard WebKit hands the page. As for a drop, only
        // the person's paste (a posted Cmd-V records nothing).
        let pasted: @MainActor () -> Void = { [weak self] in
            guard let self, AgentPanePersonInput.isPerson(answering: gestureRouter.input) else { return }
            model.droppedPaths.stash(AgentPaneDroppedPaths.fileURLs(on: .general), kind: .paste)
        }
        (page.onFilesDropped, page.onPaste) = (dropped, pasted)
        // Both engines: the page host relays the report (a Chromium page's menu waits for it).
        page.addMessageHandler(Self.contextMenuHandler) { [weak self] body in
            self?.receiveContextMenuReport(body)
            // A More press opens its own menu: no right-click menu waits for it.
            if AgentPaneContextMenu.popUpAnchor(report: body) == nil { self?.menuReports.reported() }
        }
        page.chromiumMenuWait = { [weak self] in await self?.menuReports.untilReported() }
        page.contextMenuEditor = { [weak self] menu in self?.editContextMenu(menu) }
    }

    /// Undoes ``installContextMenu()`` when the pane closes.
    func removeContextMenu() {
        page.removeMessageHandler(Self.contextMenuHandler)
        page.chromiumMenuWait = nil
        page.contextMenuEditor = nil
        page.onFilesDropped = nil
        page.onPaste = nil
    }

    /// The page's report for the menu about to open (nil: the pointer is not on a message). A
    /// report from a message's More button (`popUp`) opens that message's menu under the button now.
    func receiveContextMenuReport(_ body: Any?) {
        if let anchor = AgentPaneContextMenu.popUpAnchor(report: body) {
            let target = AgentPaneMessageTarget(report: body)
            // The menu opens after the page's message callback returns (Chrome posts a context menu's show the same
            // way, RenderViewContextMenuMac::Show), from a run-loop callout and not inside a scheduler task: its
            // tracking loop then lets the scheduler's turns keep running, and they never re-enter a running drain.
            // main-hop-allow: menu tracking must start from a run-loop callout (MainRunLoopBlock), outside the scheduler's drain
            MainRunLoopBlock.perform { [weak self] in self?.popUpMessageMenu(target: target, anchor: anchor) }
            return
        }
        messageMenuTarget = AgentPaneMessageTarget(report: body)
        menuSelection = AgentPaneContextMenu.selection(report: body)
    }

    /// Builds the pane's menu from WebKit's for the last report, which it uses up.
    func editContextMenu(_ menu: NSMenu) {
        let target = messageMenuTarget, selection = menuSelection
        messageMenuTarget = nil
        menuSelection = nil
        fillContextMenu(menu, target: target, selection: selection)
    }

    /// More (…) on a message's action row: the menu a right-click on that message opens, with the
    /// same items, under the button (`anchor`, CSS px in the page's viewport).
    private func popUpMessageMenu(target: AgentPaneMessageTarget?, anchor: CGRect) {
        let view: NSView = page.focusView
        guard let target, view.window != nil else { return }
        let menu = NSMenu()
        fillContextMenu(menu, target: target, selection: nil)
        guard !menu.items.isEmpty else { return }
        // View points per CSS px, as the page host shows it (`uiScale` times its zoom).
        let zoom = CGFloat(Double(DesignSettings.shared.uiScale) * page.additionalZoom)
        let left = anchor.minX * zoom, bottom = anchor.maxY * zoom + 2
        menu.popUp(positioning: nil, at: NSPoint(x: left, y: view.isFlipped ? bottom : view.bounds.height - bottom), in: view)
    }

    /// The pane's menu for `target` and `selection` in `menu`, which holds WebKit's items (none for More).
    private func fillContextMenu(_ menu: NSMenu, target: AgentPaneMessageTarget?, selection: String?) {
        let chatMenu = target == nil && selection == nil ? model.chatMenuItems?() ?? [] : []
        AgentPaneContextMenu.rebuild(menu, target: target, selection: selection, devTools: DevTools.isEnabled, chatMenu: chatMenu,
                                     scope: themeScope.fullStrength, actions: .init(
            copy: { [weak self] text in self?.copyText(text) },
            fork: { [weak self] seq in self?.fork(through: seq) },
            retry: { [weak self] row in self?.runMessageAction("chat.retryPrompt", ["rowId": row]) },
            edit: { [weak self] text in self?.runMessageAction("chat.editPrompt", ["text": text]) },
            open: { [weak self] url in self?.openLink(url) },
            linkItems: { [queries = model.replyLinks.workspaceQueries] in LinkMenu(queries: queries).linkItems(for: $0) },
            pathItems: { [weak self] path in self?.pathMenuItems(path) },
            search: { [weak self] text in self?.model.onSearchWeb?(text) },
            page: { [weak self] name, params in self?.runMessageAction(name, params) },
            pasteTarget: page.webKitEngine, // WebKit's Paste item only; a Chromium menu keeps its own
            inspectElement: AgentPaneTunables.pointerInspector.value ? {
                NotificationCenter.default.post(name: .cmuxNextInspectUIElement, object: self)
            } : nil))
    }

    /// Retry, Edit and Resend, Open Image and a path's Open: the page's own actions, with the menu choice as the gesture.
    private func runMessageAction(_ name: String, _ params: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return }
        AgentPanePersonInput.record(model.transport.gestures, input: gestureRouter.input)
        evaluateScript("window.cmuxAcpmuxActions?.['\(name)']?.(\(String(decoding: data, as: UTF8.self)));")
    }

    /// Open Link: outside the pane, on the rule a click on the link follows.
    private func openLink(_ url: URL) {
        AgentPanePersonInput.record(model.transport.gestures, input: gestureRouter.input)
        _ = AgentPaneNavigation.openOutside(url, gestures: model.transport.gestures) { self.openURL($0, []) }
    }

    /// Fork from Here: the turn footer's fork, through the page's own action. The menu choice is
    /// the user's gesture, as a native permission shortcut is.
    private func fork(through seq: Int) {
        AgentPanePersonInput.record(model.transport.gestures, input: gestureRouter.input)
        evaluateScript("window.cmuxAcpmuxActions?.['chat.fork']?.({ throughSeq: \(seq) });")
    }
}
