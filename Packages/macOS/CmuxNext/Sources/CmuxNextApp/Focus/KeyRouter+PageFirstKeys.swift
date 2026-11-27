import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextFocusUI

// cmux shortcuts win over a web page unless browser focus mode is on (Lawrence 2026-11-11: "we should only
// direct keyboard shortcuts into the website itself if focus mode for website is on, else all keyboard shortcuts
// should go to cmux itself"; Linear's own Cmd-B swallowed Toggle Sidebar). The one exception is Find and its
// neighbors: Google Sheets takes Cmd-F for its own search with `preventDefault` (Lawrence 2026-10-23), so those
// keys go to the page first and cmux runs Find only when the engine reports the page left the key unhandled.
// Chromium reports it through `CefKeyboardHandler::OnKeyEvent` (`cmux_shim_set_unhandled_key_handler`); WebKit
// sends the same key-down back to `NSApp.sendEvent` (`WebViewImpl::doneWithKeyEvent`), as it does for any app's
// menus. Typing, Copy, Paste, Undo and Select All are no cmux shortcuts: they reach the page as always. Focus mode
// hands the page every key.
extension KeyRouter {
    /// The actions a page may own: Find and its neighbors. Every other cmux shortcut (Toggle Sidebar on Cmd-B,
    /// Reload, Zoom, Back, new tab, Cmd-1 to Cmd-9) runs before the page.
    nonisolated static let pageOwnableActions: Set<ActionID> = ["find", "findNext", "findPrevious", "browser.findPrevious",
                                                                "useSelectionForFind"]

    /// Whether `candidate` waits for the page in `focus` instead of running first: one of ``pageOwnableActions``,
    /// while a page that reports unhandled keys has the keyboard and browser focus mode is off.
    nonisolated static func offersToPage(_ candidate: Candidate, event: NSEvent, focus: FocusState, facts: Facts) -> Bool {
        guard facts.pageReportsUnhandledKeys, case .browserPage = focus.resolved, !focus.isBrowserFocusModeActive,
              case .registry = candidate.source, !devToolsActions.contains(candidate.id) else { return false }
        return candidate.tier != .system && pageOwnableActions.contains(candidate.id)
    }

    /// The browser tab `controller`'s focused pane shows while a page has the keyboard.
    func focusedBrowserTab(in controller: WindowController) -> (any BrowserTab)? {
        guard case .browserPage = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .browser(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return nil }
        return entry.tab
    }

    /// Holds `candidate` until the page of `tab` reports `event` unhandled.
    func offerToPage(_ event: NSEvent, candidate: Candidate, context: KeyContext, window: String, tab: ObjectIdentifier) {
        pageFirstOffer.offer(event, HeldPageAction(candidate: candidate, context: context, window: window), tab: tab)
        trace?("dispatcher: the page gets the key first; \(candidate.id.rawValue) runs if it is left unhandled")
    }

    /// A WebKit page did not handle `event` and sent it back to `NSApp.sendEvent`: runs the action
    /// held for it. Matched by identity only, since WebKit resends the very event it was given; a
    /// decided key that was never offered (a view re-sending a chord cmux ran) runs nothing.
    func runResentPageKey(_ event: NSEvent) -> Bool {
        guard let held = pageFirstOffer.takeResent(event) else { return false }
        run(held.candidate, context: held.context, window: held.window)
        return true
    }

    /// The page of `tab` did not handle `event`: runs the action held for it. Returns whether one ran.
    func runUnhandledPageKey(_ event: NSEvent, from tab: ObjectIdentifier) -> Bool {
        guard let held = pageFirstOffer.take(event, from: tab) else { return false }
        run(held.candidate, context: held.context, window: held.window)
        return true
    }
}
