/// What started a Claude account switch.
enum ClaudeAccountSwitchTrigger: Sendable {
    /// The user picked an account from a menu, the command palette or the CLI.
    case manual
    /// cmux switched on its own, for example after a usage limit.
    case automatic
}
