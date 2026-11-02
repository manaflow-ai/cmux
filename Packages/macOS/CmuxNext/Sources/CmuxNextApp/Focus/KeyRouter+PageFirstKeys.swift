import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocus

// A web page keeps the shortcuts it handles. Chrome gives a page every key but its reserved
// window keys first; Google Sheets takes Cmd-F for its own search with `preventDefault`. cmux
// does the same in a Chromium tab: these keys go to the page first, and cmux runs its action
// only when Chromium reports the page left the key unhandled (`CefKeyboardHandler::OnKeyEvent`,
// `cmux_shim_set_unhandled_key_handler`).
extension KeyRouter {
    /// Navigation actions a page may own too: Find and its neighbors. Every other navigation
    /// and system action (new tab, close, Cmd-1 to Cmd-9, splits, focus moves) acts on the
    /// window and runs before the page, as Chrome's reserved keys do, unless it is typed with
    /// one of ``BrowserChordTable/pageEditingChords`` (see ``offersToPage(_:event:focus:facts:)``).
    nonisolated static let pageOwnableActions: Set<ActionID> = ["find", "findNext", "findPrevious", "useSelectionForFind"]

    /// Whether `candidate` waits for the page in `focus` instead of running first: a content
    /// action, one of ``pageOwnableActions``, or any navigation action typed with one of
    /// ``BrowserChordTable/pageEditingChords`` (Cmd-B is Bold in Google Docs and Gmail before it
    /// is Toggle Sidebar), while a page that reports unhandled keys has the keyboard. The
    /// DevTools chords keep running first; a Ghostty keybind never waits.
    nonisolated static func offersToPage(_ candidate: Candidate, event: NSEvent, focus: FocusState, facts: Facts) -> Bool {
        guard facts.pageReportsUnhandledKeys, case .browserPage = focus.resolved, !focus.isBrowserFocusModeActive,
              case .registry = candidate.source, !devToolsActions.contains(candidate.id) else { return false }
        switch candidate.tier {
        case .content: return true
        case .navigation: return pageOwnableActions.contains(candidate.id) || BrowserChordTable.isPageEditingChord(event)
        case .system: return false
        }
    }

    /// The browser tab `controller`'s focused pane shows while a page has the keyboard.
    func focusedBrowserTab(in controller: WindowController) -> (any BrowserTab)? {
        guard case .browserPage = controller.focus.state.resolved, let pane = controller.focus.state.resolved.pane,
              case .browser(let entry)? = controller.content?.paneController(key: pane)?.currentContent else { return nil }
        return entry.tab
    }

    /// Holds `candidate` until the page of `tab` reports `event` unhandled.
    func offerToPage(_ event: NSEvent, candidate: Candidate, context: KeyContext, window: String, tab: ObjectIdentifier) {
        pageFirstOffer.offer(event, PageFirstKeyOffer.Held(candidate: candidate, context: context, window: window, tab: tab))
        trace?("dispatcher: the page gets the key first; \(candidate.id.rawValue) runs if it is left unhandled")
    }

    /// The page of `tab` did not handle `event`: runs the action held for it. Returns whether one ran.
    func runUnhandledPageKey(_ event: NSEvent, from tab: ObjectIdentifier) -> Bool {
        guard let held = pageFirstOffer.take(event, from: tab) else { return false }
        run(held.candidate, context: held.context, window: held.window)
        return true
    }
}
