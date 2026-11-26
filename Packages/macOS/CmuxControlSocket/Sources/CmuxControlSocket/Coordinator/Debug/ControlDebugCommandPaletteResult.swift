#if DEBUG
/// One command-palette result row for `debug.command_palette.results`
/// (the Sendable twin of the app's `CommandPaletteDebugResultRow`).
public struct ControlDebugCommandPaletteResult: Sendable, Equatable {
    /// The command's stable identifier.
    public let commandID: String
    /// The row title.
    public let title: String
    /// The shortcut hint, if the command has one.
    public let shortcutHint: String?
    /// The trailing label, if the row has one.
    public let trailingLabel: String?
    /// The fuzzy-match score.
    public let score: Int

    /// Creates a result row.
    ///
    /// - Parameters:
    ///   - commandID: The command's stable identifier.
    ///   - title: The row title.
    ///   - shortcutHint: The shortcut hint, if any.
    ///   - trailingLabel: The trailing label, if any.
    ///   - score: The fuzzy-match score.
    public init(commandID: String, title: String, shortcutHint: String?, trailingLabel: String?, score: Int) {
        self.commandID = commandID
        self.title = title
        self.shortcutHint = shortcutHint
        self.trailingLabel = trailingLabel
        self.score = score
    }
}
#endif
