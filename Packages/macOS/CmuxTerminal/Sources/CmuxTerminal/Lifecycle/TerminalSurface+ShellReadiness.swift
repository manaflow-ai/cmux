extension TerminalSurface {
    /// Delivers this generation's startup input once, after shell integration reports readiness.
    ///
    /// Callers must validate the reporting terminal lifecycle before forwarding the prompt.
    /// Surface transfers retain the gate on the surface itself; no timer or replay is needed.
    @MainActor
    public func shellDidBecomeReadyForStartupInput() {
        guard surface != nil,
              let input = startupInputGate.takeForPrompt(generation: terminalLifecycleId) else { return }
        sendStartupInputAfterExplicitInput(input)
    }
}
