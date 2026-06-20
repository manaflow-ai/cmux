/// A single rendered row in the command-palette result list.
///
/// Rows are immutable value snapshots fed to the paired UI's list view; the
/// view never reads back into the palette's mutable state.
public struct CommandPaletteRenderResultRow: Identifiable, Equatable, Sendable {
    /// The command identifier this row represents (also its list identity).
    public let id: String
    /// The command title shown on the row.
    public let title: String
    /// Indices of `title` characters matched by the current query, for
    /// highlight rendering.
    public let matchedIndices: Set<Int>
    /// The optional trailing accessory (shortcut hint or kind label).
    public let trailingLabel: CommandPaletteRenderTrailingLabel?

    /// Creates a result row from its rendered components.
    public init(
        id: String,
        title: String,
        matchedIndices: Set<Int>,
        trailingLabel: CommandPaletteRenderTrailingLabel?
    ) {
        self.id = id
        self.title = title
        self.matchedIndices = matchedIndices
        self.trailingLabel = trailingLabel
    }
}
