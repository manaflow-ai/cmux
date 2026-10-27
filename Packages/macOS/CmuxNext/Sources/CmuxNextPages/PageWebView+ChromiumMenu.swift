public import AppKit
import Foundation

// A Chromium page's right-click menu and the person's gestures in it: Chromium's own menu never
// shows (the CEF runtime hands the click to the page host), so the host builds the menu the WebKit
// page shows (``PageWebView/contextMenuEditor``), and a real key, click or menu choice backs the
// page's calls as the person's gesture, as in the WebKit view (``PageWKWebView``).
extension PageWebView {
    /// A real key or mouse event reached the Chromium page at `uptime` (`systemUptime`).
    func chromiumUserInput(at uptime: TimeInterval) {
        chromiumUserEventUptime = uptime
        noteTouch()
    }

    /// The uptime of the person's key or mouse event within `seconds`, in whichever engine shows
    /// the page, else nil: what backs `PageCallContext.userGesture`.
    func recentUserGestureEvent(within seconds: TimeInterval = 1,
                                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard chromiumSession != nil else { return webKitPieces?.view.recentUserGestureEvent(within: seconds, now: now) }
        guard let last = chromiumUserEventUptime, now - last <= seconds else { return nil }
        return last
    }

    /// Shows the host's menu for a right-click in the Chromium page: Copy on a selection, edited by
    /// ``contextMenuEditor`` (or kept to the desktop default), at the click. Nothing shows when the
    /// menu ends up empty. Chromium hears the menu closed either way.
    func showChromiumMenu(_ request: PageChromiumContextMenu) {
        guard let wait = chromiumMenuWait else { return buildChromiumMenu(request) }
        // task-owner: one menu per right-click; Chromium waits for it to close (`finish`)
        Task { @MainActor [weak self] in
            await wait()
            guard let self else { return request.finish() }
            self.buildChromiumMenu(request)
        }
    }

    private func buildChromiumMenu(_ request: PageChromiumContextMenu) {
        defer { request.finish() }
        let menu = NSMenu()
        if !request.selection.isEmpty {
            let copy = Self.menuItem(Self.copyTitle) { [weak self] in self?.copyChromiumSelection() }
            copy.identifier = NSUserInterfaceItemIdentifier(PageSelectionMenu.copyItem)
            menu.addItem(copy)
        }
        if let contextMenuEditor { contextMenuEditor(menu) } else { Self.keepDefaultMenuItems(in: menu) }
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return }
        chromiumMenuPresenter(menu, NSPoint(x: request.location.x, y: request.location.y), self)
        // The menu tracked the person's own pointer and keys until it closed: what they chose (or
        // their dismissal) is a gesture, as a WebKit page's menu choice is. Page calls a row
        // starts arrive after this.
        chromiumUserInput(at: ProcessInfo.processInfo.systemUptime)
    }

    /// Copies the Chromium page's selection, as WebKit's Copy does (``PageChromiumPage/copySelection()``).
    private func copyChromiumSelection() {
        chromiumSession?.page.copySelection()
    }

    /// The page's selected text, in whichever engine shows it (empty for none). In Chromium it runs
    /// through ``PageChromiumPage/evaluate(_:)``, which makes no DevTools call on renderer paths.
    public func selectedText() async -> String {
        let script = "String(getSelection())"
        guard let page = chromiumSession?.page else {
            return (try? await webKitPieces?.view.evaluateJavaScript(script)) as? String ?? "" // MQ12 allowed: the page the person acts on shows
        }
        return (try? await page.evaluate(script)) as? String ?? ""
    }

    /// Runs an editing action (`cut:`, `copy:`, `paste:`, `pasteAsPlainText:`) as the page's own
    /// responder action, in whichever engine shows it: the page never reads the pasteboard.
    public func performEdit(_ action: Selector) {
        guard chromiumSession != nil else {
            if let view = webKitPieces?.view { NSApp.sendAction(action, to: view, from: nil) }
            return
        }
        // The Chromium page has the keys in its own window: its view is the first responder there.
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
