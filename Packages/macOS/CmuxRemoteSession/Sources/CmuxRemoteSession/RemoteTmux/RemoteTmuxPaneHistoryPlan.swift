import Foundation

/// The `capture-pane` row ranges that read one pane's tmux history in bounded pieces.
///
/// A single `capture-pane -S -` answers with one `%begin`/`%end` block holding the
/// whole history, and the control stream treats a block over its size limit as a
/// broken stream. Reading the history as several smaller captures keeps every block
/// well under that limit. Rows are numbered the way tmux numbers them: `-1` is the
/// newest history row and `-historySize` the oldest.
///
/// tmux answers every chunk of a load back to back, so the plan also caps the total it
/// asks for. The caller measures a few of the newest rows first
/// (``sampleRows(historySize:paneWidth:)`` and ``bytesPerRow(sampledRows:)``) and passes
/// the bytes it can keep; the plan reads only the newest rows that are expected to fit.
/// That keeps a long, wide or colorful history from sending far more than the caller
/// keeps.
///
/// The oldest chunk starts at `-` (the start of history) rather than at a number, so
/// rows that scrolled into history after the plan was made are still read. When the
/// history is longer than the plan reads (``maximumRows``, the byte budget, or
/// ``maximumChunks`` on a very wide pane) the oldest chunk starts at the cap instead and
/// ``isTruncated`` says so.
///
/// ```swift
/// let plan = RemoteTmuxPaneHistoryPlan(
///     historySize: 5_000,
///     paneWidth: 200,
///     maximumCommandBlockBytes: 16_777_216,
///     maximumBytes: 12 * 1_024 * 1_024,
///     bytesPerRow: RemoteTmuxPaneHistoryPlan.bytesPerRow(sampledRows: newestRows) ?? 1
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

    /// The most history rows one load plans to read. When the oldest chunk starts at `-`,
    /// rows that scroll into history after the plan is made are read too, so a load can
    /// paint a few more rows than this without being truncated.
    public static let maximumRows = 100_000
    /// The most bytes one cell can take in `capture-pane -e` output. tmux 3.7 writes 55
    /// for a cell that changes bold, italic, underline, strikethrough and its 24-bit
    /// foreground, background and underline colors; this rounds that up.
    public static let maximumEncodedBytesPerCell = 64
    /// The most rows in one chunk, however narrow the pane.
    public static let maximumChunkRows = 2_000
    /// The most chunks one load reads. All of them go to tmux in one command queue, and the
    /// control client refuses a write that would leave more than 256 KiB pending on tmux's
    /// stdin. A chunk's command is under 64 bytes, so this keeps the queue to half of that.
    /// On a pane so wide that this binds before ``maximumRows``, the load reads the newest
    /// rows that fit and ``isTruncated`` says so.
    public static let maximumChunks = 2_048

    /// The most rows the sample capture reads.
    public static let maximumSampleRows = 500
    /// The most bytes the sample capture can take, judged by ``maximumEncodedBytesPerCell``.
    public static let maximumSampleBytes = 1_024 * 1_024

    /// Ranges oldest first, ending at row `-1`.
    public let chunks: [Chunk]
    /// History rows the chunks cover when the plan is made.
    public let historyRows: Int
    /// Whether the plan reads less history than tmux holds: tmux holds more than
    /// ``maximumRows``, more than the byte budget is expected to hold, or more than a very
    /// wide pane fits in ``maximumChunks``.
    public let isTruncated: Bool

    /// How many of the newest rows to capture to measure a pane's row size: at most
    /// ``maximumSampleRows``, and few enough that a sample of the densest output stays
    /// within ``maximumSampleBytes``.
    /// - Parameter historySize: The pane's `history_size`.
    /// - Parameter paneWidth: The pane's width in cells.
    /// - Returns: The rows to capture, 0 when the pane has no history.
    public static func sampleRows(historySize: Int, paneWidth: Int) -> Int {
        let densest = max(1, paneWidth) * maximumEncodedBytesPerCell
        return min(max(0, historySize), maximumSampleRows, max(1, maximumSampleBytes / densest))
    }

    /// The bytes one row of `sampledRows` takes on average, counted as the receiver holds a
    /// history row: its bytes and a CR LF.
    /// - Parameter sampledRows: Rows from `capture-pane -p -e`, without line endings.
    /// - Returns: The average rounded up, or nil for an empty sample.
    public static func bytesPerRow(sampledRows: [String]) -> Int? {
        guard !sampledRows.isEmpty else { return nil }
        let bytes = sampledRows.reduce(0) { $0 + $1.utf8.count + 2 }
        return (bytes + sampledRows.count - 1) / sampledRows.count
    }

    /// Cells per chunk for a stream whose command blocks hold at most `bytes`, so that a
    /// chunk of the densest output fills at most half a block.
    /// - Parameter bytes: The largest command block the control stream accepts.
    /// - Returns: The most cells one chunk may hold, at least 1.
    public static func maximumChunkCells(forCommandBlockBytes bytes: Int) -> Int {
        max(1, bytes / 2 / maximumEncodedBytesPerCell)
    }

    /// Plans the captures for a pane.
    /// - Parameter historySize: The pane's `history_size`.
    /// - Parameter paneWidth: The pane's width in cells. A wide pane gets proportionally
    ///   fewer rows per chunk.
    /// - Parameter maximumCommandBlockBytes: The largest command block the control stream
    ///   accepts before it treats the stream as broken. Every chunk holds at least one row,
    ///   so a pane wider than ``maximumChunkCells(forCommandBlockBytes:)`` gets one-row
    ///   chunks that can exceed the half-block budget.
    /// - Parameter maximumRows: The most history rows to read; defaults to ``maximumRows``.
    /// - Parameter maximumBytes: The most history bytes to ask for, judged by `bytesPerRow`;
    ///   no limit by default.
    /// - Parameter bytesPerRow: The bytes one history row is expected to take, usually
    ///   ``bytesPerRow(sampledRows:)`` of the newest rows.
    public init(
        historySize: Int,
        paneWidth: Int,
        maximumCommandBlockBytes: Int,
        maximumRows: Int = Self.maximumRows,
        maximumBytes: Int = .max,
        bytesPerRow: Int = 1
    ) {
        let chunkCells = Self.maximumChunkCells(forCommandBlockBytes: maximumCommandBlockBytes)
        // No row floor: on a very wide pane even a few rows can pass the cell bound.
        let rowsPerChunk = max(1, min(Self.maximumChunkRows, chunkCells / max(1, paneWidth)))
        let available = max(0, historySize)
        let rows = min(
            available,
            max(0, maximumRows),
            Self.maximumChunks * rowsPerChunk,
            max(0, maximumBytes) / max(1, bytesPerRow)
        )
        let truncated = available > rows
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
