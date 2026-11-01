public import AppKit
import CmuxNextCompat
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
        guard chromiumSession != nil else { return webView.recentUserGestureEvent(within: seconds, now: now) }
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
        let menu = NSMenu()
        if !request.selection.isEmpty {
            let copy = Self.menuItem(Self.copyTitle) { [weak self] in self?.copyChromiumSelection() }
            copy.identifier = NSUserInterfaceItemIdentifier(PageSelectionMenu.copyItem)
            menu.addItem(copy)
        }
        if let contextMenuEditor { contextMenuEditor(menu) } else { Self.keepDefaultMenuItems(in: menu) }
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return request.finish() }
        // The menu tracks from a run-loop callout of its own, never inline. The request comes inside
        // a CEF pump pass (the pump skips a pass it re-enters, so Chromium stood still while the
        // menu was open), and on the agent chat inside a main-actor job after `chromiumMenuWait`
        // (the main queue does not drain inside its own job, so every main-actor reply, transcript
        // update and Chromium event waited behind the open menu). The click that closed the menu
        // then waited for that backlog: "clicking out of a fucking context menu is sometimes slow
        // as fucking balls" (Leo, 2026-10-29). From a callout the menu's tracking loop keeps the
        // main queue and the pump running, as WebContextMenu and BrowserContextMenuBuilder do.
        let point = NSPoint(x: request.location.x, y: request.location.y)
        MainRunLoopBlock.perform { [weak self] in
            defer { request.finish() }
            guard let self else { return }
            chromiumMenuPresenter(menu, point, self)
            // The menu tracked the person's own pointer and keys until it closed: what they chose
            // (or their dismissal) is a gesture, as a WebKit page's menu choice is. Page calls a
            // row starts arrive after this.
            chromiumUserInput(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Copies the Chromium page's selection, as WebKit's Copy does.
    private func copyChromiumSelection() {
        guard let page = chromiumSession?.page else { return }
        // task-owner: one copy per menu choice; ends with the page's answer
        Task { _ = try? await page.devTools("Runtime.evaluate", params: ["expression": "document.execCommand('copy')", "userGesture": true]) }
    }

    /// The page's selected text, in whichever engine shows it (empty for none).
    public func selectedText() async -> String {
        let script = "String(getSelection())"
        guard let page = chromiumSession?.page else {
            return (try? await webView.evaluateJavaScript(script)) as? String ?? ""
        }
        guard let json = try? await page.devTools("Runtime.evaluate", params: ["expression": script, "returnByValue": true]) else { return "" }
        return ChromiumPageHostWire.evaluationString(json) ?? ""
    }

    /// Runs an editing action (`cut:`, `copy:`, `paste:`, `pasteAsPlainText:`) as the page's own
    /// responder action, in whichever engine shows it: the page never reads the pasteboard.
    public func performEdit(_ action: Selector) {
        guard chromiumSession != nil else {
            NSApp.sendAction(action, to: webView, from: nil)
            return
        }
        // The Chromium page has the keys in its own window: its view is the first responder there.
        if action == #selector(NSText.paste(_:)) { chromiumPasted() }
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
