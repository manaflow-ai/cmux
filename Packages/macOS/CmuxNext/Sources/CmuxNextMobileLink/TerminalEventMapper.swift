import CmuxMobileHost
import CmuxNextDaemon
import CmuxTerminalStream
import Foundation

/// Attach events to `terminal-snapshot-v1` (a value; one per attach).
struct TerminalEventMapper: Sendable {
    /// Grid generation of the last READY (or of the byte replay).
    private(set) var generation: UInt32 = 0
    /// Host PTY offset the viewer holds after the last mapped frame.
    private(set) var offset: UInt64 = 0
    private(set) var cols: Int?
    private(set) var rows: Int?
    /// nil until a READY arrives: an older host's byte replay.
    private(set) var snapshotVersion: UInt16?

    mutating func map(_ event: TerminalChannelEvent) -> [MobileTerminalEvent] {
        switch event {
        case .snapshot(let frame):
            return snapshot(frame)
        case .output(let data, _):
            guard !data.isEmpty else { return [] }
            offset += UInt64(data.count)
            return [.frame(TerminalFrame(kind: .bytes, generation: generation, offset: offset, payload: data))]
        case .replay(let replay):
            return byteReplay(replay, reset: false)
        case .resized(let replay):
            generation &+= 1
            return byteReplay(replay, reset: true)
        case .colorsChanged, .scrollChanged:
            return []
        case .closed:
            return [.closed]
        }
    }

    private mutating func snapshot(_ frame: TerminalSnapshotFrame) -> [MobileTerminalEvent] {
        let cut = UInt32(truncatingIfNeeded: frame.generation)
        switch frame.phase {
        case .ready:
            var events: [MobileTerminalEvent] = []
            if let newCols = frame.cols, let newRows = frame.rows, newCols != cols || newRows != rows || cut != generation {
                cols = newCols
                rows = newRows
                events.append(.size(generation: cut, cols: newCols, rows: newRows))
            }
            generation = cut
            offset = frame.offset
            snapshotVersion = frame.version
            events.append(.frame(TerminalFrame(kind: .snapshotReady, generation: cut, offset: frame.offset,
                                               snapshotVersion: frame.version, payload: frame.data)))
            return events
        case .history:
            return [.frame(TerminalFrame(kind: .snapshotHistory, generation: cut, offset: frame.offset,
                                         snapshotVersion: frame.version, payload: frame.data))]
        case .images:
            // Kitty image replay is not on the phone wire yet (ios-rewrite.md 10.6).
            return []
        }
    }

    /// A byte-replay attach (no snapshot capability): the viewer runs in
    /// replay mode, so a resize rebuilds the mirror with a reset first.
    private mutating func byteReplay(_ replay: TerminalReplay, reset: Bool) -> [MobileTerminalEvent] {
        cols = replay.cols
        rows = replay.rows
        var payload = reset ? Data("\u{1b}c".utf8) : Data()
        payload.append(replay.data)
        payload.append(replay.pending)
        offset += UInt64(payload.count)
        return [.size(generation: generation, cols: replay.cols, rows: replay.rows),
                .frame(TerminalFrame(kind: .bytes, generation: generation, offset: offset, payload: payload))]
    }
}
