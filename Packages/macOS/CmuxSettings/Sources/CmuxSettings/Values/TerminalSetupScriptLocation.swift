/// The destination cmux uses when launching an automatic repository setup script.
public enum TerminalSetupScriptLocation: String, CaseIterable, Sendable, SettingCodable {
    /// Opens the setup script in an unfocused terminal tab in the current pane.
    case backgroundTab

    /// Opens the setup script in a side-by-side terminal split.
    case verticalSplit

    /// Opens the setup script in a stacked terminal split.
    case horizontalSplit
}
