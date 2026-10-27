extension TerminalSession {
    /// Applies the state Ghostty sent that still waits for a frame, or for a hidden terminal to show
    /// (``GhosttyActionMailbox``). A reader of ``model`` that must not miss it calls it first: a save at
    /// quit, and a surface swap, whose old surface takes its mailbox with it.
    public func applyWaitingActions() {
        surfaceView.bridgeObject.flushActions()
    }
}
