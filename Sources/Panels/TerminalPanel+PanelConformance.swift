extension TerminalPanel {
    // These zero-argument overloads are the Panel protocol witnesses and must not gain parameters.
    func focus() {
        focus(resumeRestoredAgent: true)
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        restoreFocusIntent(intent, resumeRestoredAgent: true)
    }
}
