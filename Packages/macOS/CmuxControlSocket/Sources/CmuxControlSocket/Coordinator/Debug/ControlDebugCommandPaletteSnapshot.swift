#if DEBUG
/// The command palette's query/mode/results snapshot for
/// `debug.command_palette.results` (the Sendable twin of the app's
/// `CommandPaletteDebugSnapshot`).
public struct ControlDebugCommandPaletteSnapshot: Sendable, Equatable {
    /// The current query text.
    public let query: String
    /// The palette mode (e.g. `commands`).
    public let mode: String
    /// The result rows, in display order.
    public let results: [ControlDebugCommandPaletteResult]

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - query: The current query text.
    ///   - mode: The palette mode.
    ///   - results: The result rows, in display order.
    public init(query: String, mode: String, results: [ControlDebugCommandPaletteResult]) {
        self.query = query
        self.mode = mode
        self.results = results
    }

    /// The empty snapshot (the legacy `CommandPaletteDebugSnapshot.empty`:
    /// empty query, `commands` mode, no results).
    public static let empty = ControlDebugCommandPaletteSnapshot(query: "", mode: "commands", results: [])
}
#endif
