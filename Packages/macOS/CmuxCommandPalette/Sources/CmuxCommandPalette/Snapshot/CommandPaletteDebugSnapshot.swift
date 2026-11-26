/// A point-in-time snapshot of the command-palette contents for a window.
///
/// Captured by the UI and stored per window so automation and the debug
/// surface can inspect the current query, mode, and rendered results.
public struct CommandPaletteDebugSnapshot: Sendable {
    /// The query string currently driving result matching.
    public let query: String
    /// The active palette mode (for example `commands` or `rename_input`).
    public let mode: String
    /// The rendered result rows in display order.
    public let results: [CommandPaletteDebugResultRow]

    /// Creates a debug snapshot.
    public init(query: String, mode: String, results: [CommandPaletteDebugResultRow]) {
        self.query = query
        self.mode = mode
        self.results = results
    }

    /// An empty snapshot used as the default for windows with no palette state.
    public static let empty = CommandPaletteDebugSnapshot(query: "", mode: "commands", results: [])
}
