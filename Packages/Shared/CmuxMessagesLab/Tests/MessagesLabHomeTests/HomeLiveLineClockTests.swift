import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The live line's elapsed-time clock is a one-shot deadline from the host (CmuxNext: a visible-class
/// MainDeadline named `Home.liveLine.clock`), armed for the next whole second and only while a line
/// shows; no repeating timer (p14-energy-067f).
@MainActor @Suite struct HomeLiveLineClockTests {
    typealias HandDeadline = NativeScrollDeadlineTests.HandDeadline

    @Test func theClockArmsForTheNextSecondOnlyWhileALineShows() throws {
        let t0 = HomeTurnStatusTests.t0
        var now = t0.addingTimeInterval(0.25)
        let line = HomeLiveLine(now: { now })
        var shown: [String?] = []
        line.dispatch = { shown.append($0) }
        let clock = HandDeadline(owner: "Home.liveLine.clock", exact: false)
        line.useClock(clock)
        #expect(!clock.isPending, "no line: no clock")

        line.show(HomeLiveActivity(line: "Checking on a31", since: t0))
        #expect(clock.isPending)
        let first = try #require(clock.delay)
        #expect(abs(first - 0.75) < 1e-9, "the first second of the line, not a second from now")

        now = t0.addingTimeInterval(1)
        clock.fire()
        let text = try #require(shown.last ?? nil)
        #expect(text.hasSuffix("1s"), "the second shows when it comes: \(text)")
        #expect(clock.isPending, "each second arms the next")
        let next = try #require(clock.delay)
        #expect(abs(next - 1) < 1e-9)

        line.stop()
        #expect(!clock.isPending, "a stopped line wakes nobody")
    }

    @Test func untilTheNextSecond() {
        #expect(abs(HomeLiveLine.untilNextSecond(0.25) - 0.75) < 1e-9)
        #expect(HomeLiveLine.untilNextSecond(3) == 1)
        #expect(abs(HomeLiveLine.untilNextSecond(-0.3) - 0.3) < 1e-9, "a start a moment ahead (clock skew)")
        #expect(HomeLiveLine.untilNextSecond(.nan) == 1)
    }
}
