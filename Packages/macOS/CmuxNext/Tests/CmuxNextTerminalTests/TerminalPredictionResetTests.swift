import AppKit
@testable import CmuxNextTerminal
import Foundation
import Testing

/// When predicted glyphs must go at once, through the real session and Ghostty surface of a remote terminal
/// (``TerminalPredictionLatencyTests/harness(roundTripMs:loss:predict:seed:)``): a replay that replaces the screen,
/// even an empty one.
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
}
