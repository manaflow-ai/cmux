/// The result of resolving a keyboard copy-mode key event.
public enum TerminalKeyboardCopyModeResolution: Equatable, Sendable {
    /// Performs a resolved action with a repeat count.
    case perform(TerminalKeyboardCopyModeAction, count: Int)

    /// Consumes the key event without performing an immediate action.
    case consume
}
