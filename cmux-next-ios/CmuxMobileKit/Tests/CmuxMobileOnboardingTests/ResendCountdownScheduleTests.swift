import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileDesign

/// The sign-in code screen's "Resend in 0:12" counted down once a second, and
/// kept redrawing "Resend code" every second after it reached 0. It now draws
/// the same ticks up to the first one at or past the end, then stops.
@Suite struct ResendCountdownScheduleTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000.4)

    static func text(_ resendAt: Date, _ date: Date) -> String {
        let remaining = max(0, Int(resendAt.timeIntervalSince(date).rounded(.up)))
        return remaining > 0 ? "Resend in 0:\(String(format: "%02d", remaining))" : "Resend code"
    }

    @Test func aMinuteOnTheScreenRedrawsOnlyWhileItCounts() {
        let resendAt = Self.start.addingTimeInterval(30)
        let periodic = Array(PeriodicTimelineSchedule(from: Self.start, by: 1).entries(from: Self.start, mode: .normal)
            .prefix { $0 < Self.start.addingTimeInterval(60) })
        let countdown = Array(CountdownSchedule(from: Self.start, until: resendAt).entries(from: Self.start, mode: .normal)
            .prefix { $0 < Self.start.addingTimeInterval(60) })
        print("ResendCountdownScheduleTests: one minute, resend at 30 s: \(periodic.count) redraws before, \(countdown.count) after")
        // The same moments while it counts, and the last one draws "Resend code".
        #expect(countdown == Array(periodic.prefix(countdown.count)))
        #expect(countdown.last.map { Self.text(resendAt, $0) } == "Resend code")
        // Every tick it dropped would have drawn "Resend code" again.
        for date in periodic.dropFirst(countdown.count) {
            #expect(Self.text(resendAt, date) == "Resend code")
        }
        #expect(countdown.count < periodic.count)
    }
}
