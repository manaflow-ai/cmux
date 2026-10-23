import AppKit
import Foundation
@testable import CmuxNextTerminal
import Testing

/// perf-lead.md issue 5 (key to frame < 10 ms p95): a keystroke's echo, and every chunk a busy
/// terminal prints, waited for the main actor before it was queued for parsing, so the echo of a
/// key waited for whatever else held the main thread (a streaming chat, twenty busy terminals).
/// Once a terminal shows content, its output is parsed with the main thread busy.
@MainActor @Suite(.serialized) struct TerminalOutputOffMainTests {
    /// Spins the main thread (no yield, no run-loop turn) until `done` or `seconds` pass.
    private func busyMain(for seconds: Double, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
        }
        return done()
    }

    @Test func outputIsParsedWhileTheMainThreadIsBusy() async throws {
        _ = NSApplication.shared
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        defer { io.finish(); session.close() }
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let lane = try #require(session.surfaceView.lane)

        // The first content goes through the main actor (it ends the empty surface).
        io.send(.replay(Data("$ ".utf8)))
        for _ in 0..<2000 where !session.surfaceHasContent { await Task.yield() }
        try #require(session.surfaceHasContent, "the replay reached the surface")
        await lane.drained()

        // An echo while the main thread is busy: parsed without it.
        let before = lane.parsedChunks
        io.send(.output(Data("a".utf8)))
        let parsed = busyMain(for: 2) { lane.parsedChunks > before }
        #expect(parsed, "the echo waited for the main thread before it was parsed")

        // A later replay still swaps the surface on the main actor, in stream order.
        io.send(.replay(Data("$ b".utf8)))
        for _ in 0..<2000 where session.swappedSurfaces == 0 { await Task.yield() }
        #expect(session.swappedSurfaces == 1)
        #expect(session.surfaceView.lane !== lane, "output after the swap goes to the fresh surface")
    }
}
