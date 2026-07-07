struct TerminalPointerFocusActivationPolicy: Sendable {
    func shouldForwardToTerminal(wasFocusedBeforePointerDown: Bool) -> Bool {
        wasFocusedBeforePointerDown
    }
}
