/// Shell invocation mode understood by the terminal spawn layer.
public enum TerminalShellStartupMode: String, CaseIterable, Sendable {
    /// Start an interactive login shell.
    case login
    /// Start an interactive non-login shell.
    case nonLogin
}
