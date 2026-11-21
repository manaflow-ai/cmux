#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileAgentChat

/// A working row's elapsed time redraws only when its text changes, at the
/// moment it changes. The text is nothing for the first 5 s, then "· 12s",
/// "· 1m 5s": a row redrew every second from its start, 5 times for nothing.
/// The clock is injected: each row's start and the minute watched are fixed
/// dates, and the redraws are the schedule's entries in that minute (each one
/// re-runs the row's `TimelineView` content).
@Suite struct WorkingLabelRedrawTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000.5)
    static let minute: TimeInterval = 60

    /// Row `i` of `count` started `i * 0.9 + 0.3` s before the minute: the
    /// first rows are still in their quiet 5 s, each at its own sub-second phase.
    static func rowStarts(_ count: Int) -> [Date] {
        (0..<count).map { start.addingTimeInterval(-(Double($0) * 0.9 + 0.3)) }
    }

    /// The dates in [start, end) the label redraws at.
    static func redraws(since: Date, from start: Date, to end: Date) -> [Date] {
        var dates: [Date] = []
        for date in WorkingLabel.elapsedSchedule(since: since).entries(from: start, mode: .normal) {
            guard date < end else { break }
            dates.append(date)
        }
        return dates
    }

    /// The moments in (start, end) the text changes: it can change only on a
    /// whole second after `since`.
    static func changes(since: Date, from start: Date, to end: Date) -> [Date] {
        var dates: [Date] = []
        var second = Int((start.timeIntervalSince(since)).rounded(.down)) + 1
        while true {
            let date = since.addingTimeInterval(TimeInterval(second))
            guard date < end else { break }
            if date > start,
               WorkingLabel.elapsedText(since: since, at: date) != WorkingLabel.elapsedText(since: since, at: date.addingTimeInterval(-1)) {
                dates.append(date)
            }
            second += 1
        }
        return dates
    }

    @Test func twentyWorkingRowsRedrawOnlyWhenTheirTextChanges() {
        let end = Self.start.addingTimeInterval(Self.minute)
        var redrawn = 0
        var needed = 0
        for since in Self.rowStarts(20) {
            let dates = Self.redraws(since: since, from: Self.start, to: end)
            let changes = Self.changes(since: since, from: Self.start, to: end)
            redrawn += dates.count
            // One draw when the row appears, then one per change.
            needed += 1 + changes.count
            // The same text at the same moments: every change is drawn when it happens.
            let later = dates.filter { $0 > Self.start }
            #expect(Set(later).isSuperset(of: changes), "row since \(since): a change was not drawn")
            // And nothing else: each redraw after the first shows a new text.
            for date in later {
                #expect(WorkingLabel.elapsedText(since: since, at: date) != WorkingLabel.elapsedText(since: since, at: date.addingTimeInterval(-1)),
                        "row since \(since) redrew at \(date.timeIntervalSince(since)) s with the same text")
            }
        }
        print("WorkingLabelRedrawTests: 20 working rows, one minute: \(redrawn) redraws, \(needed) needed")
        #expect(redrawn == needed)
    }

    @Test func theTextIsTheSame() {
        let since = Self.start
        #expect(WorkingLabel.elapsedText(since: since, at: since.addingTimeInterval(4.99)) == nil)
        #expect(WorkingLabel.elapsedText(since: since, at: since.addingTimeInterval(5)) == "· 5s")
        #expect(WorkingLabel.elapsedText(since: since, at: since.addingTimeInterval(59.9)) == "· 59s")
        #expect(WorkingLabel.elapsedText(since: since, at: since.addingTimeInterval(65)) == "· 1m 5s")
    }

    /// A start a little ahead of the phone's clock (another device's time): nothing
    /// shows until 5 s after it, then each second, as before.
    @Test func aStartAheadOfTheClockWaitsForItsFifthSecond() {
        let since = Self.start.addingTimeInterval(2.3)
        let dates = Self.redraws(since: since, from: Self.start, to: Self.start.addingTimeInterval(10))
        #expect(dates.first == Self.start)
        #expect(Array(dates.dropFirst()) == [5, 6, 7].map { since.addingTimeInterval($0) })
        #expect(WorkingLabel.elapsedText(since: since, at: Self.start) == nil)
    }

    /// The row's first draw shows the text of the moment it appears.
    @Test func theFirstDrawShowsTheCurrentText() {
        for since in Self.rowStarts(20) {
            let first = Self.redraws(since: since, from: Self.start, to: Self.start.addingTimeInterval(Self.minute)).first
            #expect(first.map { WorkingLabel.elapsedText(since: since, at: $0) } == WorkingLabel.elapsedText(since: since, at: Self.start))
        }
    }
}
#endif
