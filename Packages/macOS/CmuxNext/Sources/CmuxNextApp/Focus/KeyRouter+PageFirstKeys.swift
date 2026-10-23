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

    /// Holds `candidate` until the page reports `event` unhandled.
    func offerToPage(_ event: NSEvent, candidate: Candidate, context: KeyContext, window: String) {
        pageFirstOffer.offer(event, PageFirstKeyOffer.Held(candidate: candidate, context: context, window: window))
        trace?("dispatcher: the page gets the key first; \(candidate.id.rawValue) runs if it is left unhandled")
    }

    /// The page did not handle `event`: runs the action held for it. Returns whether one ran.
    func runUnhandledPageKey(_ event: NSEvent) -> Bool {
        guard let held = pageFirstOffer.take(event) else { return false }
        run(held.candidate, context: held.context, window: held.window)
        return true
    }
}
