import AppKit
@testable import CmuxNextTerminal
import Dispatch
import Foundation
import Testing

/// The session's events loop runs off the main actor (G4), but the session's last release must
/// still run on main: its views are AppKit views, and ``TerminalSurfaceView``'s deinit frees the
/// Ghostty surface (closing its output lane first) only on the main thread. An owner that drops a
/// session while an event is in flight (a READY restore waiting for its lane) must not leak the
/// surface with its renderer and IO threads.
@MainActor @Suite(.serialized) struct TerminalSessionReleaseTests {
    @Test func aSessionDroppedDuringARestoreFreesItsSurfaceOnMain() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = ScriptedTerminalIO(answersTerminalQueries: false)
        defer { io.finish() }
        var session: TerminalSession? = TerminalSession(io: io)
        try #require(session?.surfaceView.surface != nil, "libghostty created no surface")
        let lane = try #require(session?.surfaceView.lane)
        weak var surfaceView = session?.surfaceView

        // Hold the lane so the READY restore stays in flight (the session waits for its drain).
        let gate = DispatchSemaphore(value: 0)
        lane.perform { _ in _ = gate.wait(timeout: .now() + .seconds(10)) }
        io.send(.snapshot(Data("not a snapshot".utf8), phase: .ready))
        await lane.queued(atLeast: 1)
        try #require(lane.pendingBytes > 0, "the READY never reached the lane")

        // The owner drops the session mid-restore; only the in-flight event keeps it alive.
        session = nil
        gate.signal()
        // The session's deinit (on main) cancels its events loop, which ends the IO's stream; the
        // deinit then releases the views before it returns, so one main-actor hop later they are gone.
        await io.streamEnded()
        await MainActor.run {}
        try #require(surfaceView == nil, "the session was never released")

        // Freed on main: the lane was closed before ghostty_surface_free, so it runs nothing more.
        // Released off main, the deinit skipped the free and the lane still holds the surface.
        let ran = RanFlag()
        lane.perform { _ in ran.set() }
        await lane.drained()
        #expect(!ran.value, "the surface outlived its session (released off main)")
    }
}

/// Whether a lane block ran. Written on the lane's queue; read after `drained()` (which orders
/// after every queued block), so the two never race.
private nonisolated final class RanFlag: @unchecked Sendable {
    // Written only by the lane block, read only after the lane drained past it.
    private(set) var value = false
    func set() { value = true }
}
