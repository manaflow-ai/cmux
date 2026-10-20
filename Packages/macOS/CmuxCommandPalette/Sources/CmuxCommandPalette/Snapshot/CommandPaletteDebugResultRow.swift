/// A single rendered result row captured for command-palette debug inspection.
///
/// Mirrors the shape the command-palette UI renders, so automation and the
/// debug snapshot can assert against exactly what the user sees.
public struct CommandPaletteDebugResultRow: Sendable {
    /// Stable identifier of the command backing the row.
    public let commandId: String
    /// User-visible title of the row.
    public let title: String
    /// Optional shortcut hint shown on the trailing edge of the row.
    public let shortcutHint: String?
    /// Optional trailing label (for example a scope or status badge).
    public let trailingLabel: String?
    /// Fuzzy-match score that ordered the row in the result list.
    public let score: Int

    /// Creates a debug result row.
    public init(
        commandId: String,
        title: String,
        shortcutHint: String?,
        trailingLabel: String?,
        score: Int
    ) {
        self.commandId = commandId
        self.title = title
        self.shortcutHint = shortcutHint
        self.trailingLabel = trailingLabel
        self.score = score
    }
}
