import AppKit
import CmuxNextFocus
import CmuxNextTerminal

// Up and Down into a surface's primary-input history (Home's message box)
// from anywhere in the surface but the input itself: the arrow-key half of
// the primary-input redirect (KeyRouter+TypeAhead.swift). The input's own
// Up and Down recall through its own key handling (first visual line rule).
extension KeyRouter {
    /// A plain Up (true) or Down (false) arrow: no Command, Control, Option
    /// or Shift (those select, jump or run shortcuts). Nil for any other key.
    nonisolated static func historyArrow(_ event: NSEvent) -> Bool? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return true
        case 125: return false
        default: return nil
        }
    }

    /// A plain Up or Down while a surface with a primary-input history has
    /// the keyboard outside that input: the input takes the keyboard and the
    /// history steps. The arrow test runs first, so typing never looks up the
    /// window (typing-latency path).
    func recallsPrimaryInputHistory(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let older = Self.historyArrow(event), let window, !(window.firstResponder is TerminalSurfaceView) else { return false }
        if (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        let resolved = controller.focus.state.resolved
        guard Self.mayHavePrimaryInput(resolved), let pane = resolved.pane,
              let target = controller.content?.paneController(key: pane)?.currentContent?.historyTarget,
              target.historyTakesArrowKeys(from: window.firstResponder), target.recallHistory(older: older) else { return false }
        decided.add(event)
        return true
    }
}
