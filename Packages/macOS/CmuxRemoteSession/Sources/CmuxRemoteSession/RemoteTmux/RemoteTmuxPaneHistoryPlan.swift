import Foundation

/// The `capture-pane` row ranges that read one pane's tmux history in bounded pieces.
///
/// A single `capture-pane -S -` answers with one `%begin`/`%end` block holding the
/// whole history, and the control stream treats a block over its size limit as a
/// broken stream. Reading the history as several smaller captures keeps every block
/// well under that limit. Rows are numbered the way tmux numbers them: `-1` is the
/// newest history row and `-historySize` the oldest.
///
/// The oldest chunk starts at `-` (the start of history) rather than at a number, so
/// rows that scrolled into history after the plan was made are still read. When the
/// history is longer than ``maximumRows`` the oldest chunk starts at the cap instead
/// and ``isTruncated`` says so.
///
/// ```swift
/// let plan = RemoteTmuxPaneHistoryPlan(
///     historySize: 5_000,
///     paneWidth: 200,
///     maximumCommandBlockBytes: 16_777_216
/// )
/// let commands = plan.chunks.map { "capture-pane -p -e -t %3 \($0.captureArguments)" }
/// ```
public struct RemoteTmuxPaneHistoryPlan: Equatable, Sendable {
    /// One `capture-pane -S <start> -E <end>` range.
    public struct Chunk: Equatable, Sendable {
        /// The `-S` row: `-` for the start of history, otherwise a negative row number.
        public let start: String
        /// The `-E` row, a negative row number.
        public let end: String

        /// Creates a range from its `-S` and `-E` rows.
        /// - Parameter start: The first row, `-` or a negative row number.
        /// - Parameter end: The last row, a negative row number.
        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }

        /// The `-S`/`-E` arguments for this range.
        public var captureArguments: String { "-S \(start) -E \(end)" }
    }

    /// The most history rows one load reads.
    public static let maximumRows = 100_000
    /// The most bytes one cell can take in `capture-pane -e` output. tmux 3.7 writes 55
    /// for a cell that changes bold, italic, underline, strikethrough and its 24-bit
    /// foreground, background and underline colors; this rounds that up.
    public static let maximumEncodedBytesPerCell = 64
    /// The most bytes one cell takes in plain `capture-pane -J` text, which has no escape
    /// sequences: a UTF-8 character with a few combining marks.
    public static let plainTextBytesPerCell = 16
    /// The most rows in one chunk, however narrow the pane.
    public static let maximumChunkRows = 2_000

    /// Ranges oldest first, ending at row `-1`.
    public let chunks: [Chunk]
    /// History rows the chunks cover.
    public let historyRows: Int
    /// Whether tmux holds more history than ``maximumRows``.
    public let isTruncated: Bool

    /// Cells per chunk for a stream whose command blocks hold at most `bytes`, so that a
    /// chunk of the densest output fills at most half a block.
    /// - Parameter bytes: The largest command block the control stream accepts.
    /// - Parameter bytesPerCell: The most bytes one cell can take in the capture's output.
    /// - Returns: The most cells one chunk may hold, at least 1.
    public static func maximumChunkCells(
        forCommandBlockBytes bytes: Int,
        bytesPerCell: Int = maximumEncodedBytesPerCell
    ) -> Int {
        max(1, bytes / 2 / max(1, bytesPerCell))
    }

    /// Plans the captures for a pane.
    /// - Parameter historySize: The pane's `history_size`.
    /// - Parameter paneWidth: The pane's width in cells. A wide pane gets proportionally
    ///   fewer rows per chunk.
    /// - Parameter maximumCommandBlockBytes: The largest command block the control stream
    ///   accepts before it treats the stream as broken.
    /// - Parameter maximumRows: The most history rows to read; defaults to ``maximumRows``.
    /// - Parameter bytesPerCell: The most bytes one cell can take in the capture's output;
    ///   defaults to ``maximumEncodedBytesPerCell`` for `capture-pane -e`. Plain text captures
    ///   pass ``plainTextBytesPerCell``.
    public init(
        historySize: Int,
        paneWidth: Int,
        maximumCommandBlockBytes: Int,
        maximumRows: Int = Self.maximumRows,
        bytesPerCell: Int = Self.maximumEncodedBytesPerCell
    ) {
        let available = max(0, historySize)
        let rows = min(available, max(0, maximumRows))
        let truncated = available > rows
        let chunkCells = Self.maximumChunkCells(
            forCommandBlockBytes: maximumCommandBlockBytes, bytesPerCell: bytesPerCell)
        // No row floor: on a very wide pane even a few rows can pass the cell bound.
        let rowsPerChunk = max(1, min(Self.maximumChunkRows, chunkCells / max(1, paneWidth)))
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
