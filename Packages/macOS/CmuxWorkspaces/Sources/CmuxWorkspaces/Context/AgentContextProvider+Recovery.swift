public extension AgentContextProvider {
    /// Returns the provider-native slash command for a recovery action.
    ///
    /// A fresh context is `/clear` for both supported providers. Keeping the
    /// provider command mapping here prevents app-level injection code from
    /// guessing which TUI command implements the configured semantic action.
    ///
    /// - Parameter action: The semantic recovery action selected by the user.
    /// - Returns: The provider-native slash command without a trailing Return.
    func recoveryCommand(for action: AgentContextInjectionAction) -> String {
        switch (self, action) {
        case (.claudeCode, .compact), (.codex, .compact):
            "/compact"
        case (.claudeCode, .clear), (.codex, .clear):
            "/clear"
        }
    }
}
