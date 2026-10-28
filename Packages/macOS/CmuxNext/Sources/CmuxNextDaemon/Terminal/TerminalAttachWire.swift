import Foundation
import os

/// `vt-state` and `resized`: a JSON attach line, or the meta of a REPLAY or GRID frame, which names the
/// lengths of the raw bytes after it (`data_len`, `pending_len`) instead of carrying them.
struct TerminalVTStateWire: Decodable {
    var surface: SurfaceID?
    var cols: Int
    var rows: Int
    var data: Data?
    var replay: Data?
    var colors: TerminalColors?
    var kittyImageAliases: [KittyImageAlias]?
    var kittyGraphicsState: KittyGraphicsState?
    var pending: Data?
    /// Frame meta only: the replay bytes that follow it (REPLAY; a GRID's replay is the rest of its payload).
    var dataLen: Int?
    /// Frame meta only: the pending-sequence bytes that end its raw bytes.
    var pendingLen: Int?

    enum CodingKeys: String, CodingKey {
        case surface, cols, rows, data, replay, colors, pending
        case kittyImageAliases = "kitty_image_aliases"
        case kittyGraphicsState = "kitty_graphics_state"
        case dataLen = "data_len"
        case pendingLen = "pending_len"
    }

    /// The replay of a JSON line, whose bytes it carries.
    var terminalReplay: TerminalReplay {
        terminalReplay(data: replay ?? data ?? Data(), pending: pending ?? Data())
    }

    /// The replay of a frame, whose bytes are `data` and `pending`.
    func terminalReplay(data: Data, pending: Data) -> TerminalReplay {
        TerminalReplay(cols: cols, rows: rows, data: data, colors: colors,
                       kittyImageAliases: kittyImageAliases ?? [], kittyGraphicsState: kittyGraphicsState,
                       pending: pending)
    }
}

/// `snapshot {phase, generation, offset, version, cols?, rows?, colors?, data}`: a JSON attach line, or the
/// meta of a SNAPSHOT frame, which has `data_len` instead of `data`.
/// `marker_epoch` and `active_top_marker` (row markers for `terminal-history`) are not used by the view.
struct TerminalSnapshotWire: Decodable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")

    var surface: SurfaceID?
    var phase: String
    var generation: UInt64
    var offset: UInt64
    var version: UInt16
    var cols: Int?
    var rows: Int?
    var colors: TerminalColors?
    /// JSON lines only.
    var data: Data?
    /// Frame meta only: the bytes of `data` that follow it.
    var dataLen: Int?
    /// History chunks: `deflate` (raw DEFLATE) and the inflated length.
    var compression: String?
    var rawBytes: Int?
    /// A local-history READY: `history: "local"` with the host's check.
    var history: String?
    var historyRows: UInt64?
    var historyDigest: String?
    var skippedImages: Int?

    enum CodingKeys: String, CodingKey {
        case surface, phase, generation, offset, version, cols, rows, colors, data, compression, history
        case dataLen = "data_len"
        case rawBytes = "raw_bytes"
        case historyRows = "history_rows"
        case historyDigest = "history_digest"
        case skippedImages = "skipped_images"
    }

    /// The check of a local-history READY; nil (a plain READY whose
    /// history is lost) when it is missing or malformed.
    var localHistory: TerminalLocalHistoryCheck? {
        guard phase == "ready", history == "local", let historyRows,
              let digest = historyDigest.flatMap(TerminalLocalHistoryCheck.digest(hex:)) else { return nil }
        return TerminalLocalHistoryCheck(rows: historyRows, digest: digest)
    }

    /// The frame whose (still compressed) bytes are `encoded`; nil for an unknown phase, a READY without its
    /// grid (it cannot lock the mirror's grid), or a chunk that does not inflate (it would corrupt the restore).
    func frame(data encoded: Data) -> TerminalSnapshotFrame? {
        guard let phase = TerminalSnapshotFrame.Phase(rawValue: phase),
              phase != .ready || (cols != nil && rows != nil)
        else { return nil }
        guard let data = TerminalSnapshotInflate.inflate(encoded, compression: compression, rawBytes: rawBytes) else {
            Self.logger.error("""
                snapshot \(self.phase, privacy: .public) chunk refused: compression \(self.compression ?? "none", privacy: .public), \
                raw_bytes \(self.rawBytes ?? -1), \(encoded.count) bytes
                """)
            return nil
        }
        return TerminalSnapshotFrame(phase: phase, generation: generation, offset: offset, version: version,
                                     cols: cols, rows: rows, colors: colors, localHistory: localHistory,
                                     skippedImages: skippedImages, data: data)
    }
}
