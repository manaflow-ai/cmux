import AppKit
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// Live libghostty surfaces for tests (no window).
@MainActor
enum LiveTerminal {
    nonisolated final class Sink: @unchecked Sendable {
        var data = Data()
    }

    /// `manual`: the surface answers queries and reflows on a grid change, as
    /// the PTY owner's terminal does; otherwise a MANUAL_MIRROR viewer.
    static func session(manual: Bool = false) throws -> (TerminalSession, ScriptedTerminalIO) {
        _ = NSApplication.shared
        try #require(GhosttyRuntime.shared.app != nil, "libghostty did not start")
        let io = ScriptedTerminalIO(answersTerminalQueries: !manual)
        return (TerminalSession(io: io), io)
    }

    static func encodeReady(_ session: TerminalSession) async throws -> Data {
        let lane = try #require(session.surfaceView.lane)
        let sink = Sink()
        nonisolated(unsafe) let userdata = Unmanaged.passRetained(sink).toOpaque()
        defer { Unmanaged<Sink>.fromOpaque(userdata).release() }
        lane.perform { surface in
            _ = ghostty_surface_encode_snapshot(surface, { userdata, bytes, length in
                guard let userdata, let bytes else { return }
                Unmanaged<Sink>.fromOpaque(userdata).takeUnretainedValue().data.append(bytes, count: length)
            }, userdata, GHOSTTY_SURFACE_SNAPSHOT_READY)
        }
        await lane.drained()
        return sink.data
    }

    /// The owner's history check (`ghostty_surface_history_digest`).
    static func historyCheck(_ session: TerminalSession) async throws -> (rows: UInt64, digest: Data) {
        let lane = try #require(session.surfaceView.lane)
        nonisolated final class Box: @unchecked Sendable { var rows: UInt64 = 0; var digest = Data(count: Int(GHOSTTY_SURFACE_HISTORY_DIGEST_LEN)) }
        let box = Box()
        lane.perform { surface in
            var rows: UInt64 = 0
            let count = box.digest.count
            _ = box.digest.withUnsafeMutableBytes { out in
                ghostty_surface_history_digest(surface, &rows, out.bindMemory(to: UInt8.self).baseAddress, count)
            }
            box.rows = rows
        }
        await lane.drained()
        return (box.rows, box.digest)
    }

    /// The whole screen, scrollback included.
    static func screenText(_ session: TerminalSession) -> String {
        guard let surface = session.surfaceView.surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Waits (bounded, test-only) for the session's events and `condition`.
    static func until(_ session: TerminalSession, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            await session.surfaceView.lane?.drained()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
