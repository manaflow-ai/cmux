/// Decides whether a macOS delete equivalent belongs to a focused terminal.
///
/// AppKit offers Command-Backspace and Command-ForwardDelete to menu items
/// before a terminal responder receives `keyDown`. The app target supplies the
/// responder state and converts its event flags to
/// ``TerminalKeyboardCopyModeModifiers``; this policy keeps the routing rule
/// independent of the window and menu implementation.
///
/// - Parameter optionModifier: Whether Option was present on the event. The
///   copy-mode modifier set intentionally does not model Option, so callers
///   must pass this separately when deciding whether a Command chord is an
///   exact match.
public func terminalDeleteEquivalentShouldDispatch(
    keyCode: UInt16,
    firstResponderIsTerminal: Bool,
    firstResponderHasMarkedText: Bool = false,
    modifiers: TerminalKeyboardCopyModeModifiers,
    optionModifier: Bool = false
) -> Bool {
    guard firstResponderIsTerminal, !firstResponderHasMarkedText, !optionModifier else { return false }
    guard keyCode == 51 || keyCode == 117 else { return false }

    let normalized = modifiers.subtracting([.numericPad, .function, .capsLock])
    return normalized == [.command]
}
