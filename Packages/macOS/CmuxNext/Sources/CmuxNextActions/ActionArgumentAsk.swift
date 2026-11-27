/// One argument a handler asks the person for inline in Cmd-Shift-P, also when the schema marks it
/// optional: a menu or shortcut Rename with no name asks for the name as a palette text step, not
/// in a separate dialog (``ActionRegistry/ask(_:_:_:)``).
public nonisolated struct ActionArgumentAsk: Sendable, Hashable {
    /// The argument's schema name (`name`).
    public var argument: String
    /// The text the step starts from, selected (the current name); nil starts empty. Return on the
    /// untouched text closes without running, since it is a snapshot that may be stale.
    public var initialText: String?

    /// - Parameters:
    ///   - argument: The argument's schema name.
    ///   - initialText: The text the step starts from; nil starts empty.
    public init(argument: String, initialText: String? = nil) {
        self.argument = argument
        self.initialText = initialText
    }
}
