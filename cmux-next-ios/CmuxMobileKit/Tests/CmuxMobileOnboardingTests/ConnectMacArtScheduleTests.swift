import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileOnboarding

/// S6 (`design/ios.md`): Connect your Mac's wait drew 60 frames a second for
/// as long as it waited, though its pulse plays only 1.5 s of every 2.4 s.
@Suite struct ConnectMacArtScheduleTests {
    private let since = Date(timeIntervalSinceReferenceDate: 1_000)

    private func frames(_ mode: ConnectMacArtSchedule.Mode, from start: Date, until end: Date) -> [Date] {
        var out: [Date] = []
        for date in ConnectMacArtSchedule(mode: mode).entries(from: start, mode: .normal) {
            if date >= end { break }
            out.append(date)
            if out.count > 10_000 { break }
        }
        return out
    }

    private var pulses: ConnectMacArtSchedule.Mode { .pulses(since: since, period: 2.4, active: 1.5) }

    @Test func oneCycleDrawsThePulseAndItsEndOnly() {
        let cycle = frames(pulses, from: since, until: since.addingTimeInterval(2.4))
        // 90 frames inside the 1.5 s pulse at 60 a second, one at its end; 144 before.
        #expect(cycle.count == 91)
        #expect(cycle.last == since.addingTimeInterval(1.5))
    }

    @Test func nothingDrawsInTheGapAndTheNextPulseStartsOnTime() {
        let two = frames(pulses, from: since, until: since.addingTimeInterval(4.8))
        let gap = two.filter { $0 > since.addingTimeInterval(1.5) && $0 < since.addingTimeInterval(2.4) }
        #expect(gap.isEmpty)
        #expect(two.contains(since.addingTimeInterval(2.4)))
        #expect(two.count == 182)
    }

    @Test func framesAlwaysMoveForward() {
        // Starting mid-gap, and on a pulse's end, never repeats a date.
        for offset in [0.0, 1.5, 1.9, 2.4 - 1e-9, 7.3] {
            let dates = frames(pulses, from: since.addingTimeInterval(offset), until: since.addingTimeInterval(offset + 10))
            #expect(!dates.isEmpty)
            #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test func midGapStartWaitsForTheNextPulse() {
        let dates = frames(pulses, from: since.addingTimeInterval(1.9), until: since.addingTimeInterval(2.5))
        #expect(dates.first == since.addingTimeInterval(1.9))
        #expect(dates.dropFirst().first == since.addingTimeInterval(2.4))
    }

    @Test func stillDrawsOnce() {
        #expect(frames(.still, from: since, until: since.addingTimeInterval(60)).count == 1)
    }

    @Test func ridingDrawsEveryFrame() {
        // 60 a second; the last can land a rounding error before the 1 s mark.
        #expect((60...61).contains(frames(.riding, from: since, until: since.addingTimeInterval(1)).count))
    }
}
