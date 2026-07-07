enum TerminalPointerFocusActivationDecision: Equatable, Sendable {
    case focusOnly
    case forwardToTerminal
}

struct TerminalPointerFocusActivationPolicy: Sendable {
    func decision(wasFocusedBeforePointerDown: Bool) -> TerminalPointerFocusActivationDecision {
        .forwardToTerminal
    }
}
