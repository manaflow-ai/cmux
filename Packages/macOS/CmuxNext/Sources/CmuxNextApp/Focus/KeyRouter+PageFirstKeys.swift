import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocus

// A web page keeps the shortcuts it handles. Chrome gives a page every key but its reserved
// window keys first; Google Sheets takes Cmd-F for its own search with `preventDefault`. cmux
// does the same in a Chromium tab: these keys go to the page first, and cmux runs its action
// only when Chromium reports the page left the key unhandled.
extension KeyRouter {
    /// Whether `candidate` waits for the page in `focus` instead of running first.
    nonisolated static func offersToPage(_ candidate: Candidate, focus: FocusState, facts: Facts) -> Bool {
        false
    }

    /// Holds `candidate` until the page reports `event` unhandled.
    func offerToPage(_ event: NSEvent, candidate: Candidate, context: KeyContext, window: String) {}

    /// The page did not handle `event`: runs the action held for it. Returns whether one ran.
    func runUnhandledPageKey(_ event: NSEvent) -> Bool {
        false
    }
}
