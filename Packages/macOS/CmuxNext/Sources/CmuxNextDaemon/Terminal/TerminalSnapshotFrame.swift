public import Foundation

/// One GHOSTSNP snapshot event of a snapshot attach (`terminal-snapshot-v1`
/// and `terminal-snapshot-history-v1`; cmux-tui `server/terminal_snapshot.rs`).
///
/// A `ready` frame holds the READY prefix: the host's grid, both screens,
/// modes, colors and the unfinished escape sequence at its cut. Restore it
/// in place of the terminal state, then feed later output. `history` frames
/// follow their READY (same `generation` and `offset`); their bytes,
/// concatenated, continue that snapshot through FINISH (the scrollback).
public struct TerminalSnapshotFrame: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case ready
        case history
        /// The Kitty image replay of the READY's cut (S3k), applied on the
        /// surface's trusted replay path after the history.
        case images
    }

    public var phase: Phase
    /// The host's grid generation at the cut.
    public var generation: UInt64
    /// Host byte offset of the PTY output stream at the cut.
    public var offset: UInt64
    /// GHOSTSNP format version.
    public var version: UInt16
    /// The snapshot's grid (`ready` only).
    public var cols: Int?
    public var rows: Int?
    public var colors: TerminalColors?
    /// A READY cut exactly at a host resize (`history: "local"`,
    /// `terminal-snapshot-local-history-v1`): the view reflows its own
    /// history and checks it against this. nil: history follows as chunks.
    public var localHistory: TerminalLocalHistoryCheck?
    /// Images the host left out of an images phase (its per-READY cap).
    public var skippedImages: Int?
    public var data: Data

    public init(phase: Phase, generation: UInt64, offset: UInt64, version: UInt16,
                cols: Int? = nil, rows: Int? = nil, colors: TerminalColors? = nil,
                localHistory: TerminalLocalHistoryCheck? = nil, skippedImages: Int? = nil, data: Data) {
        self.phase = phase
        self.generation = generation
        self.offset = offset
        self.version = version
        self.cols = cols
        self.rows = rows
        self.colors = colors
        self.localHistory = localHistory
        self.skippedImages = skippedImages
        self.data = data
    }
}

/// One decoded attach line and the grid generation it carries (`output` of
/// a snapshot attach), before ``TerminalSnapshotSequencer`` admits it.
struct DecodedAttachLine: Sendable, Equatable {
    var event: TerminalChannelEvent
    var generation: UInt64?
}

/// The one owner of snapshot order on an attach stream (runs on the reader
/// thread, in stream order).
///
/// - Output tagged with a generation older than the last READY belongs to a
///   screen that READY replaced: dropped.
/// - History continues only the READY with the same cut (generation and
///   offset); pages of a replaced READY would land above the wrong screen.
/// - Everything else passes unchanged, so a byte-replay attach (no
///   snapshot, untagged output) is unaffected.
struct TerminalSnapshotSequencer: Sendable {
    private(set) var generation: UInt64?
    private var cut: (generation: UInt64, offset: UInt64)?

    mutating func admit(_ line: DecodedAttachLine) -> TerminalChannelEvent? {
        switch line.event {
        case .snapshot(let frame) where frame.phase == .ready:
            generation = frame.generation
            cut = (frame.generation, frame.offset)
            return line.event
        case .snapshot(let frame):
            guard let cut, cut.generation == frame.generation, cut.offset == frame.offset else { return nil }
            return line.event
        case .output:
            if let generation, let tagged = line.generation, tagged < generation { return nil }
            return line.event
        default:
            return line.event
        }
    }
}
