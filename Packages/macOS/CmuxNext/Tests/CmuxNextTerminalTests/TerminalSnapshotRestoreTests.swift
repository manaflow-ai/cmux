import AppKit
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import Foundation
import GhosttyNextKit
import Testing

/// S2b slice 3: a GHOSTSNP snapshot from the PTY owner restores the screen
/// and the scrollback on the SAME surface (no swap), also after a canonical
/// resize, and later output continues from it. The "host" here is a second
/// live surface that encodes its own snapshot, as cmux-tui's ghostty-vt does.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalSnapshotRestoreTests {
    /// Receives `ghostty_surface_encode_snapshot` bytes on the output lane.
    private final class Sink: @unchecked Sendable {
        var data = Data()
    }

    private static func encode(_ session: TerminalSession, phase: ghostty_surface_snapshot_phase_e) async throws -> Data {
        let lane = try #require(session.surfaceView.lane)
        let sink = Sink()
        nonisolated(unsafe) let userdata = Unmanaged.passRetained(sink).toOpaque()
        defer { Unmanaged<Sink>.fromOpaque(userdata).release() }
        lane.perform { surface in
            _ = ghostty_surface_encode_snapshot(surface, { userdata, bytes, length in
                guard let userdata, let bytes else { return }
                Unmanaged<Sink>.fromOpaque(userdata).takeUnretainedValue().data.append(bytes, count: length)
            }, userdata, phase)
        }
        await lane.drained()
        return sink.data
    }

    /// The whole screen, scrollback included.
    private static func screenText(_ session: TerminalSession) -> String {
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

    /// Waits (bounded, test-only) until the session's events reached the
    /// surface and `condition` holds.
    private static func until(_ session: TerminalSession, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            await session.surfaceView.lane?.drained()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func liveSession() throws -> (TerminalSession, ScriptedTerminalIO) {
        _ = NSApplication.shared
        try #require(GhosttyRuntime.shared.app != nil, "libghostty did not start")
        let io = ScriptedTerminalIO()
        return (TerminalSession(io: io), io)
    }

    /// A host surface at 40x10 with 200 lines of scrollback and a prompt.
    private static func hostSnapshot() async throws -> (ready: Data, history: Data) {
        let (host, io) = try liveSession()
        defer { host.close() }
        io.send(.resize(cols: 40, rows: 10))
        let lines = (0..<200).map { "line \($0)\r\n" }.joined()
        io.send(.output(Data((lines + "HOST$ ").utf8)))
        await until(host) { host.surfaceView.viewportText()?.contains("HOST$") == true }
        let ready = try await encode(host, phase: GHOSTTY_SURFACE_SNAPSHOT_READY)
        let complete = try await encode(host, phase: GHOSTTY_SURFACE_SNAPSHOT_COMPLETE)
        try #require(!ready.isEmpty && complete.count > ready.count && complete.prefix(ready.count) == ready)
        return (ready, complete.suffix(from: complete.startIndex + ready.count))
    }

    @Test func aReadySnapshotRestoresInPlaceAfterACanonicalResize() async throws {
        let snapshot = try await Self.hostSnapshot()
        let (viewer, io) = try Self.liveSession()
        defer { viewer.close() }
        io.send(.resize(cols: 80, rows: 24))
        io.send(.output(Data("STALE\r\n".utf8)))
        await Self.until(viewer) { viewer.surfaceView.viewportText()?.contains("STALE") == true }
        let surface = viewer.surfaceView

        io.send(.resize(cols: 40, rows: 10))
        io.send(.snapshot(snapshot.ready, phase: .ready))
        await Self.until(viewer) { viewer.surfaceView.viewportText()?.contains("HOST$") == true }
        #expect(viewer.surfaceView === surface, "a snapshot never swaps the surface")
        let viewport = viewer.surfaceView.viewportText() ?? ""
        #expect(viewport.contains("HOST$"))
        #expect(viewport.contains("line 199"))
        #expect(!viewport.contains("STALE"))
        #expect(viewer.diagnostics.grid == TerminalGridSize(columns: 40, rows: 10))
        #expect(viewer.diagnostics.restoredSnapshots == 1)
        #expect(viewer.diagnostics.swappedSurfaces == 0)

        // History restores the scrollback above the restored screen.
        io.send(.snapshot(snapshot.history, phase: .history))
        await Self.until(viewer) { Self.screenText(viewer).contains("line 5\n") }
        #expect(Self.screenText(viewer).contains("line 0\n"))
        #expect(Self.screenText(viewer).contains("line 150\n"))

        // Live output continues from the snapshot cut.
        io.send(.output(Data("after\r\n".utf8)))
        await Self.until(viewer) { viewer.surfaceView.viewportText()?.contains("after") == true }
        #expect(viewer.surfaceView.viewportText()?.contains("HOST$ after") == true)
        #expect(viewer.surfaceView === surface)
    }

    /// A second READY (reattach, overflow, grid change) also restores in
    /// place: the old screen and its scrollback go.
    @Test func aLaterReadyReplacesTheEarlierOneInPlace() async throws {
        let snapshot = try await Self.hostSnapshot()
        let (viewer, io) = try Self.liveSession()
        defer { viewer.close() }
        io.send(.resize(cols: 40, rows: 10))
        io.send(.snapshot(snapshot.ready, phase: .ready))
        io.send(.output(Data("\r\nEXTRA\r\n".utf8)))
        await Self.until(viewer) { viewer.surfaceView.viewportText()?.contains("EXTRA") == true }
        let surface = viewer.surfaceView
        io.send(.snapshot(snapshot.ready, phase: .ready))
        await Self.until(viewer) { viewer.surfaceView.viewportText()?.contains("EXTRA") == false }
        #expect(viewer.surfaceView === surface)
        #expect(viewer.surfaceView.viewportText()?.contains("HOST$") == true)
        #expect(viewer.surfaceView.viewportText()?.contains("EXTRA") == false)
    }
}
