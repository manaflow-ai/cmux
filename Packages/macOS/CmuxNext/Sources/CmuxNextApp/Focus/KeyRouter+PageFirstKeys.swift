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
    /// window and runs before the page, as Chrome's reserved keys do.
    nonisolated static let pageOwnableActions: Set<ActionID> = ["find", "findNext", "findPrevious", "useSelectionForFind"]

    /// Whether `candidate` waits for the page in `focus` instead of running first: a content
    /// action, or one of ``pageOwnableActions``, while a page that reports unhandled keys has the
    /// keyboard. The DevTools chords keep running first; a Ghostty keybind never waits.
    nonisolated static func offersToPage(_ candidate: Candidate, focus: FocusState, facts: Facts) -> Bool {
        guard facts.pageReportsUnhandledKeys, case .browserPage = focus.resolved, !focus.isBrowserFocusModeActive,
              case .registry = candidate.source, !devToolsActions.contains(candidate.id) else { return false }
        switch candidate.tier {
        case .content: return true
        case .navigation: return pageOwnableActions.contains(candidate.id)
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

// A page's keyboard lock (`navigator.keyboard.lock()`): while the hosted page that
// has the keyboard holds one in its fullscreen (``KeyFacts/pageLocksKeys``), it gets the chords cmux would
// run and no chord arms, as Chrome's KeyboardLockController lets a fullscreen page take the browser's
// shortcuts (chrome/browser/ui/exclusive_access/keyboard_lock_controller.cc). Escape ends the lock in the
// page view (ChromiumHostExclusiveAccess).
extension KeyRouter {
    /// What a keyboard lock leaves to cmux: Ghostty's split keys, unchanged in every pane
    /// (schemas/keybindings/ghostty-reserved-keys.json, which KeyboardLockKeysTests reads), and Quit.
    nonisolated static let keyboardLockKeeps: Set<ActionID> = [
        "focusLeft", "focusRight", "focusUp", "focusDown", "splitRight", "splitDown",
        "resizePaneLeft", "resizePaneRight", "resizePaneUp", "resizePaneDown", "toggleSplitZoom", "quit",
    ]

    /// Whether a locked page takes `candidate`'s key instead of cmux.
    nonisolated static func keyboardLockTakes(_ candidate: Candidate, facts: Facts) -> Bool {
        facts.pageLocksKeys && !keyboardLockKeeps.contains(candidate.id)
    }
}
