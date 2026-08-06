/// The result of attempting to select the current finite choice.
public enum CommandPaletteArgumentSelectionResult: Sendable, Equatable {
    /// The supplied value is not declared by the current argument.
    case invalid
    /// The value was accepted and another argument remains.
    case advanced
    /// The value was accepted and all arguments are now collected.
    case completed
}
