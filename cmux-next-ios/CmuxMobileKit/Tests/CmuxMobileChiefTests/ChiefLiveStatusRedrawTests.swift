#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileChief

/// The Chief's status line redraws once a second only while it shows an
/// elapsed time. "Thinking…" (no step yet, no `since`) never changes, and it
/// redrew every second anyway. The clock is injected: fixed dates, and the
/// redraws are the schedule's entries in one minute.
@Suite struct ChiefLiveStatusRedrawTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000.25)

    static func redraws(since: Date?, in seconds: TimeInterval) -> [Date] {
        guard let schedule = ChiefLiveStatusLine.redrawSchedule(since: since, now: start) else { return [] }
        var dates: [Date] = []
        for date in schedule.entries(from: start, mode: .normal) {
            guard date < start.addingTimeInterval(seconds) else { break }
            dates.append(date)
        }
        return dates
    }

    @Test func thinkingWithoutAStepNeverRedraws() {
        let count = Self.redraws(since: nil, in: 60).count
        print("ChiefLiveStatusRedrawTests: \"Thinking…\" for one minute: \(count) redraws, 0 needed")
        #expect(count == 0)
    }

    /// What the view runs: the line's TimelineView draws when it appears, and
    /// with no time to count never again.
    @Test func theLinesTimelineDrawsOnceWithoutATime() {
        let schedule = ChiefStatusSchedule(ticks: ChiefLiveStatusLine.redrawSchedule(since: nil, now: Self.start))
        let dates = Array(schedule.entries(from: Self.start, mode: .normal).prefix(5))
        #expect(dates == [Self.start])
        let ticking = ChiefStatusSchedule(ticks: ChiefLiveStatusLine.redrawSchedule(since: Self.start, now: Self.start))
        #expect(Array(ticking.entries(from: Self.start, mode: .normal).prefix(3)).count == 3)
    }

    /// A step's line ("Editing app.ts · 12s") still redraws on every second,
    /// and each redraw shows a new time.
    @Test func aStepRedrawsEverySecondWithANewTime() {
        let since = Self.start.addingTimeInterval(-7.6)
        let dates = Self.redraws(since: since, in: 60)
        #expect(dates.count >= 60)
        for date in dates.dropFirst() {
            #expect(ChiefLiveBubble.activityLine("Editing", since: since, now: date)
                    != ChiefLiveBubble.activityLine("Editing", since: since, now: date.addingTimeInterval(-1)))
        }
    }
}
#endif
