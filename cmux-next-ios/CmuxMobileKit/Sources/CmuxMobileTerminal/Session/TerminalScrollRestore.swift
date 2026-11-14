import CoreGraphics

/// Where a reader was in a tab's scrollback, kept past the host that showed it
/// (Leo, 2026-11-14: "Every time I navigate away from it now ... I have to
/// scroll all the way back to where I was"). A tab that falls out of the warm
/// set loses its surface and its attach; its next host replays the Mac's
/// screen from scratch and, given this, puts the reader back on their rows
/// (``TerminalScrollRestore``). A page that follows the prompt has none: its
/// next host follows too. So has a full-screen app, which has no scrollback.
public struct TerminalScrollPlace: Equatable, Sendable {
    let mark: TerminalReadingMark

    /// Rows from the reader's top row to the end of the scrollback when the
    /// place was kept: the least history the next attach needs above the end
    /// (output since then only moves the rows further up).
    public var rowsFromEnd: Int { mark.rowsFromEnd }
}

/// Puts a reader back on their rows after a replay that may not hold them
/// yet. A Mac terminal attaches with its latest screen first
/// (`attach-replay-history-rows-v1`): a reattach after a dropped link, or a
/// tab's new host, may replay fewer rows than the reader was above the end.
/// Then the page asks for older rows (``replayed(totalRows:rowText:loadOlder:)``
/// returns nil and the next replay comes back here), at most
/// ``maxOlderLoads`` times; past that, or when the Mac has no older rows, the
/// page shows the oldest row it holds. A replay that holds the rows finds them
/// by their text (``TerminalReadingMark``).
///
/// The rows are counted from the end of the scrollback (``fromEnd``) once the
/// replay starts somewhere else than the rows the mark was taken in: a new
/// host's replay, or one that brought older rows. A link drop's own replay
/// keeps the row the reader had (rows that arrive during a drop only append:
/// `TerminalReadingMark`, T-LIFE-09/15).
struct TerminalScrollRestore: Equatable {
    /// Older-row fetches at most for one restore (each brings
    /// `DaemonTerminalSession.historyChunkRows` more rows).
    static let maxOlderLoads = 5

    /// The rows to find, renumbered for the last replay they were placed in.
    private(set) var mark: TerminalReadingMark
    /// The expected row is the mark's distance from the end, not its row.
    private(set) var fromEnd: Bool
    /// Older-row fetches asked for so far.
    private(set) var olderLoads = 0

    init(mark: TerminalReadingMark, fromEnd: Bool) {
        self.mark = mark
        self.fromEnd = fromEnd
    }

    init(place: TerminalScrollPlace) {
        self.init(mark: place.mark, fromEnd: true)
    }

    /// The place to keep for a later host while this restore is still waiting.
    var place: TerminalScrollPlace { TerminalScrollPlace(mark: mark) }

    /// A replay of `totalRows` rows is in: where the reader's rows are now, or
    /// nil after `loadOlder` asked for older rows (their replay comes back
    /// here). `loadOlder` returns whether a fetch was sent.
    mutating func replayed(totalRows: Int, rowText: (Int) -> String?, loadOlder: () -> Bool) -> TerminalScrollModel.Anchor? {
        // Red stub (the test commit): today's restore, the mark as it was.
        mark.locate(totalRows: totalRows, rowText: rowText)
    }
}
