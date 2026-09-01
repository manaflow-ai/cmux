/// Decides whether a macOS delete equivalent belongs to a focused terminal.
///
/// AppKit offers Command-Backspace and Command-ForwardDelete to menu items
/// before a terminal responder receives `keyDown`. The app target supplies the
/// responder state and converts its event flags to
/// ``TerminalKeyboardCopyModeModifiers``; this policy keeps the routing rule
/// independent of the window and menu implementation.
public func terminalDeleteEquivalentShouldDispatch(
    keyCode: UInt16,
    firstResponderIsTerminal: Bool,
    firstResponderHasMarkedText: Bool = false,
    modifiers: TerminalKeyboardCopyModeModifiers
) -> Bool {
    guard firstResponderIsTerminal, !firstResponderHasMarkedText else { return false }
    guard keyCode == 51 || keyCode == 117 else { return false }

    let normalized = modifiers.subtracting([.numericPad, .function, .capsLock])
    return normalized == [.command]
}
