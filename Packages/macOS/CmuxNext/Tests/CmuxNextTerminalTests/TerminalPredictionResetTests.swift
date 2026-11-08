import AppKit
@testable import CmuxNextTerminal
import Foundation
import Testing

/// When predicted glyphs must go at once, through the real session and Ghostty surface of a remote terminal
/// (``TerminalPredictionLatencyTests/harness(roundTripMs:loss:predict:seed:)``): a replay that replaces the screen,
/// even an empty one, and turning `terminal.predictiveLocalEcho` off in a running terminal.
@MainActor @Suite(.serialized)
struct TerminalPredictionResetTests {
    /// Engages prediction at a shell prompt (echoed keys at 150 ms), then cuts the link so the next keys stay
    /// speculative, and waits until the overlay draws them.
    static func speculating() async throws -> TerminalPredictionLatencyTests.Harness {
        let harness = try await TerminalPredictionLatencyTests.harness(roundTripMs: 150, loss: 0, predict: true, seed: 11)
        let session = harness.session
        for key in "echo engaged".map(String.init) {
            session.sendText(key)
            try await Task.sleep(for: .milliseconds(120)) // test: typing cadence
        }
        try await Task.sleep(for: .milliseconds(400)) // test: the last echoes land
        harness.io.onWrite.withLock { $0 = nil } // the remote never echoes what comes next
        for key in "abc".map(String.init) {
            session.sendText(key)
            try await Task.sleep(for: .milliseconds(30)) // test: typing cadence
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while Self.speculative(session) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5)) // test: waits for the overlay's draw
        }
        return harness
    }

    static func speculative(_ session: TerminalSession) -> Int {
        session.echo?.drawnLayout?.glyphs.filter { $0.standing == .speculative }.count ?? 0
    }

    /// Lets the lane run what is queued and the main actor redraw the overlay.
    static func settle(_ session: TerminalSession) async throws {
        await session.surfaceView.lane?.drained()
        try await Task.sleep(for: .milliseconds(50)) // test: the engine's redraw hop to the main actor
    }

    /// An empty VT replay that replaces the screen (a swapped-in surface whose terminal has no content yet) must
    /// withdraw what was predicted for the old screen, as a non-empty one does.
    @Test func emptyReplacingReplayWithdrawsPredictedGlyphs() async throws {
        let harness = try await Self.speculating()
        defer { harness.close() }
        let session = harness.session
        try #require(Self.speculative(session) > 0, "prediction drew no speculative glyph, so the check proves nothing")
        session.surfaceView.lane?.processOutput(Data(), replacesScreen: true)
        try await Self.settle(session)
        #expect(Self.speculative(session) == 0, "glyphs predicted for the old screen survived an empty replacing replay")
    }

    /// Empty output that does not replace the screen changes nothing.
    @Test func emptyOutputKeepsPredictedGlyphs() async throws {
        let harness = try await Self.speculating()
        defer { harness.close() }
        let session = harness.session
        let before = Self.speculative(session)
        try #require(before > 0, "prediction drew no speculative glyph, so the check proves nothing")
        session.surfaceView.lane?.processOutput(Data())
        try await Self.settle(session)
        #expect(Self.speculative(session) == before)
    }

    /// `terminal.predictiveLocalEcho` off in a running terminal (``TerminalSession/predictsLocalEcho``): what was
    /// drawn goes at once and later keys draw nothing; on again, the engine listens again from a fresh start.
    @Test func turningPredictionOffClearsGlyphsAndStopsDrawing() async throws {
        let harness = try await Self.speculating()
        defer { harness.close() }
        let session = harness.session
        try #require(Self.speculative(session) > 0, "prediction drew no speculative glyph, so the check proves nothing")
        session.predictsLocalEcho = false
        #expect(Self.speculative(session) == 0, "glyphs stayed drawn after prediction was turned off")
        #expect(harness.engine.status == .disabled)
        let watch = TerminalPredictionLatencyTests.DrawWatch()
        session.echo?.onDrawChange = { layout in if layout?.glyphs.isEmpty == false { watch.drewAfter = true } }
        defer { session.echo?.onDrawChange = nil }
        for key in "def".map(String.init) {
            session.sendText(key)
            try await Task.sleep(for: .milliseconds(30)) // test: typing cadence
        }
        try await Self.settle(session)
        #expect(!watch.drewAfter, "a glyph was drawn while prediction was off")
        session.predictsLocalEcho = true
        #expect(harness.engine.status != .disabled, "prediction stayed off after it was turned back on")
    }

    /// The app's `terminal.predictiveLocalEcho` (``TerminalLocalEchoPreference``): a session made while it is off
    /// starts with its engine off, and every session made with it follows a later change.
    @Test func sessionsFollowTheAppPreference() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let preference = TerminalLocalEchoPreference(predicts: false)
        let first = TerminalSession(io: TerminalPredictionLatencyTests.LinkIO(), ownsGeometry: false, localEcho: preference)
        defer { first.close() }
        let engine = try #require(first.echo?.engine, "a remote IO's session has no prediction engine")
        #expect(!first.predictsLocalEcho)
        #expect(engine.status == .disabled)
        preference.set(true)
        let second = TerminalSession(io: TerminalPredictionLatencyTests.LinkIO(), ownsGeometry: false, localEcho: preference)
        defer { second.close() }
        #expect(first.predictsLocalEcho && second.predictsLocalEcho)
        #expect(engine.status != .disabled)
        preference.set(false)
        #expect(!first.predictsLocalEcho && !second.predictsLocalEcho)
        #expect(engine.status == .disabled)
        #expect(second.echo?.engine.status == .disabled)
    }
}
