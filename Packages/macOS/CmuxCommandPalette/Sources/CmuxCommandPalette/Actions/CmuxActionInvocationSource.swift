/// Identifies the adapter invoking an action.
public enum CmuxActionInvocationSource: Sendable, Equatable {
    /// The command palette may collect missing arguments interactively.
    case commandPalette
    /// A CLI or socket caller must supply required arguments directly.
    case automation
}
