import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A 160 Hz display: 6.25 ms frames at full rate, 12.5 ms under WebKit's cap.
@Suite struct AgentPaneFramePacingTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let display = 6.25
    private let backoff = AgentPaneFramePacing.firstBackoff

    /// A scroll's frame intervals: `late` of every 10 take `slow` ms, the rest `fast`.
    private func scroll(_ fast: Double, late: Int = 0, slow: Double = 0, frames: Int = 120) -> [Double] {
        (0..<frames).map { $0 % 10 < late ? slow : fast }
    }

    @Test func aSmoothScrollStaysAtFullRate() {
        var pacing = AgentPaneFramePacing()
        #expect(pacing.record(intervals: scroll(display, late: 1, slow: 8), displayInterval: display, at: start))
    }

    @Test func aScrollThatMissesFramesDropsToTheCappedRate() {
        var pacing = AgentPaneFramePacing()
        #expect(!pacing.record(intervals: scroll(display, late: 4, slow: 12.5), displayInterval: display, at: start))
    }

    @Test func aShortScrollDecidesNothing() {
        var pacing = AgentPaneFramePacing()
        #expect(pacing.record(intervals: scroll(12.5, frames: AgentPaneFramePacing.minimumFrames - 1), displayInterval: display, at: start))
    }

    @Test func aCleanCappedScrollRestoresFullRateAfterTheBackoff() {
        var pacing = AgentPaneFramePacing()
        _ = pacing.record(intervals: scroll(12.5), displayInterval: display, at: start)
        #expect(!pacing.record(intervals: scroll(12.5), displayInterval: display, at: start.addingTimeInterval(backoff / 2)))
        #expect(pacing.record(intervals: scroll(12.5), displayInterval: display, at: start.addingTimeInterval(backoff + 1)))
    }

    @Test func aCappedScrollThatStillMissesFramesKeepsTheCap() {
        var pacing = AgentPaneFramePacing()
        _ = pacing.record(intervals: scroll(12.5), displayInterval: display, at: start)
        #expect(!pacing.record(intervals: scroll(12.5, late: 3, slow: 25), displayInterval: display, at: start.addingTimeInterval(backoff + 1)))
    }

    @Test func aQuickRelapseDoublesTheBackoff() {
        var pacing = AgentPaneFramePacing()
        _ = pacing.record(intervals: scroll(12.5), displayInterval: display, at: start)
        let restored = start.addingTimeInterval(backoff + 1)
        #expect(pacing.record(intervals: scroll(12.5), displayInterval: display, at: restored))
        let relapse = restored.addingTimeInterval(2)
        #expect(!pacing.record(intervals: scroll(12.5), displayInterval: display, at: relapse))
        #expect(!pacing.record(intervals: scroll(12.5), displayInterval: display, at: relapse.addingTimeInterval(backoff + 1)))
        #expect(pacing.record(intervals: scroll(12.5), displayInterval: display, at: relapse.addingTimeInterval(2 * backoff + 1)))
    }

    /// At 60 Hz the cap and the full rate are the same rate.
    @Test func aDisplayNearSixtyHertzIsLeftAtItsRate() {
        var pacing = AgentPaneFramePacing()
        #expect(pacing.record(intervals: scroll(33.3), displayInterval: 1000 / 60, at: start))
    }
}
