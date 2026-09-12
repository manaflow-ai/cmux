/// The shell invocation mode used for ordinary newly-created local surfaces.
public enum ShellStartupMode: String, CaseIterable, Sendable, SettingCodable {
    /// Start the user's shell as an interactive login shell.
    case login
    /// Start the user's shell as an interactive, non-login shell.
    case nonLogin
}
