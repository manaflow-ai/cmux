import AppKit

extension KeyRouter {
    /// A plain Up (true) or Down (false) arrow: no Command, Control, Option
    /// or Shift (those select, jump or run shortcuts). Nil for any other key.
    /// Home's message box claims these for its sent-message history
    /// (`PrimaryInputTarget.routesToPrimaryInput`).
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
}
