import Foundation

/// The `capture-pane` row ranges that read one pane's tmux history in bounded pieces.
///
/// A single `capture-pane -S -` answers with one `%begin`/`%end` block holding the
/// whole history, and the control stream treats a block over 16 MiB as a broken
/// stream. Reading the history as several smaller captures keeps every block well
/// under that limit. Rows are numbered the way tmux numbers them: `-1` is the newest
/// history row and `-historySize` the oldest.
///
/// The oldest chunk starts at `-` (the start of history) rather than at a number, so
/// rows that scrolled into history after the plan was made are still read. When the
/// history is longer than ``maximumRows`` the oldest chunk starts at the cap instead
/// and ``isTruncated`` says so.
struct RemoteTmuxPaneHistoryPlan: Equatable {
    /// One `capture-pane -S <start> -E <end>` range.
    struct Chunk: Equatable {
        let start: String
        let end: String

        /// The `-S`/`-E` arguments for this range.
        var captureArguments: String { "-S \(start) -E \(end)" }
    }

    /// The most history rows one load reads.
    static let maximumRows = 100_000
    /// Cells per chunk; a wide pane gets proportionally fewer rows.
    static let maximumChunkCells = 400_000
    static let maximumChunkRows = 2_000
    static let minimumChunkRows = 32

    /// Ranges oldest first, ending at row `-1`.
    let chunks: [Chunk]
    /// History rows the chunks cover.
    let historyRows: Int
    /// Whether tmux holds more history than ``maximumRows``.
    let isTruncated: Bool

    init(
        historySize: Int,
        paneWidth: Int,
        maximumRows: Int = Self.maximumRows,
        maximumChunkCells: Int = Self.maximumChunkCells
    ) {
        let available = max(0, historySize)
        let rows = min(available, max(0, maximumRows))
        let truncated = available > rows
        let rowsPerChunk = max(
            Self.minimumChunkRows,
            min(Self.maximumChunkRows, max(1, maximumChunkCells) / max(1, paneWidth))
        )
        var chunks: [Chunk] = []
        var top = rows
        while top > 0 {
            let bottom = max(0, top - rowsPerChunk)
            let start = chunks.isEmpty && !truncated ? "-" : "-\(top)"
            chunks.append(Chunk(start: start, end: "-\(bottom + 1)"))
            top = bottom
        }
        self.chunks = chunks
        self.historyRows = rows
        self.isTruncated = truncated
    }
}
