import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct NotificationFeedTimeLabelPolicyTests {
    @Test func formatsNowMinutesHoursAndOlderTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)))
        let policy = NotificationFeedTimeLabelPolicy(
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(policy.label(for: now.addingTimeInterval(-30)) == "now")
        #expect(policy.label(for: now.addingTimeInterval(-5 * 60)) == "5m")
        #expect(policy.label(for: now.addingTimeInterval(-2 * 3_600)) == "2h")
        let older = policy.label(for: now.addingTimeInterval(-24 * 3_600))
        #expect(older.contains("12:00") && older.contains("PM"))
    }
}
