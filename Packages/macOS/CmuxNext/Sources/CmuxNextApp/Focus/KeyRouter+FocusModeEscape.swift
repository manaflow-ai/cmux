import AppKit
import CmuxNextActions
import CmuxNextFocus

// Browser focus mode's exit gesture (classic cmux parity): Esc Esc. The page
// owns every other key while focus mode is on (``focusModeKeptActions`` aside), so this runs
// before the bare-key and chord paths.
extension KeyRouter {
    /// The system actions browser focus mode keeps from the page (Lawrence 2026-10-21: "when in
    /// focus mode cmd shift p still triggers cmux cmd shift p"): its own toggle, the exit chord
    /// beside Esc Esc, and Quit, which no page can use. The command palette, Close Tab, New
    /// Window and the rest go to the page like every other cmux shortcut.
    nonisolated static let focusModeKeptActions: Set<ActionID> = ["toggleBrowserFocusMode", "quit"]

    /// The tab in browser focus mode that has the keyboard, nil when none.
    nonisolated static func focusModeTab(_ focus: FocusState) -> String? {
        guard focus.isBrowserFocusModeActive, case .browserPage(_, let tab) = focus.resolved else { return nil }
        return tab
    }

    /// Feeds `event` to the double-Escape gesture for a window whose focus is `focus`.
    func focusModeEscapeOutcome(_ event: NSEvent, focus: FocusState) -> BrowserFocusModeEscapeExit.Outcome {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let isPlainEscape = flags.isEmpty && event.keyCode == 53
        return focusModeEscape.handle(isPlainEscape: isPlainEscape, isRepeat: event.isARepeat, timestamp: event.timestamp,
                                      focusModeTab: Self.focusModeTab(focus))
    }

    /// Runs the gesture for a key-down in `window`. Returns whether the key was consumed.
    func routesFocusModeEscape(_ event: NSEvent, in window: NSWindow?) -> Bool {
        let wasArmed = focusModeEscape.armedTab
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else {
            focusModeEscape.reset()
            showFocusModeExitArmed(nil, previous: wasArmed)
            return false
        }
        let outcome = focusModeEscapeOutcome(event, focus: controller.focus.currentState())
        showFocusModeExitArmed(focusModeEscape.armedTab, previous: wasArmed)
        switch outcome {
        case .pass, .forwardToPage:
            return false
        case .consume:
            trace?("focus mode: a repeated Escape")
            return true
        case .exit(let tab):
            trace?("focus mode: Esc Esc left browser focus mode")
            controller.focus.send(.toggleBrowserFocusMode(tab: tab))
            return true
        }
    }

    /// The toolbar badge reads "Esc again to exit" on the armed tab only.
    private func showFocusModeExitArmed(_ armed: String?, previous: String?) {
        guard armed != previous else { return }
        if let previous { services?.cache.existingBrowser(previous)?.chrome.focusModeExitArmed = false }
        if let armed { services?.cache.existingBrowser(armed)?.chrome.focusModeExitArmed = true }
    }
}
