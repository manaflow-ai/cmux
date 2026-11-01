import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeUsageLimitResetTests {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private var now: Date { date(2026, 10, 23, 18, 33, in: seoul) }

    private func parse(_ message: String, now: Date? = nil, zone: TimeZone? = nil) -> Date? {
        ClaudeUsageLimitReset.resetDate(inMessage: message, now: now ?? self.now, timeZone: zone ?? seoul)
    }

    @Test func timeWithZoneSuffix() {
        #expect(parse("You've hit your session limit · resets 6:50pm (Asia/Seoul)") == date(2026, 10, 23, 18, 50, in: seoul))
    }

    @Test func zoneSuffixOverridesFallbackZone() {
        let result = parse("5-hour limit reached ∙ resets 3pm (America/New_York)")
        #expect(result == date(2026, 10, 23, 15, 0, in: newYork))
        #expect(result == ISO8601DateFormatter().date(from: "2026-10-23T19:00:00Z"))
    }

    @Test func dateAndTimeWithoutZone() {
        let early = date(2026, 10, 1, 12, 0, in: seoul)
        #expect(parse("You've hit your weekly limit · resets Oct 3 at 9am", now: early) == date(2026, 10, 3, 9, 0, in: seoul))
    }

    @Test func timeWithoutZoneUsesLocalZone() {
        #expect(parse("resets 7pm") == date(2026, 10, 23, 19, 0, in: seoul))
    }

    @Test func pastTimeRollsToTomorrow() {
        #expect(parse("resets 9am (Asia/Seoul)") == date(2026, 10, 24, 9, 0, in: seoul))
    }

    @Test func midnightHourIsTwelveAm() {
        #expect(parse("You've hit your session limit · resets 12:10am (Asia/Seoul)") == date(2026, 10, 24, 0, 10, in: seoul))
    }

    @Test func noonHourIsTwelvePm() {
        #expect(parse("resets 12pm") == date(2026, 10, 24, 12, 0, in: seoul))
    }

    @Test func pastDateRollsToNextYear() {
        let late = date(2026, 12, 30, 12, 0, in: seoul)
        #expect(parse("resets Jan 2 at 9am", now: late) == date(2027, 1, 2, 9, 0, in: seoul))
    }

    @Test func dateEarlierToday() {
        let afternoon = date(2026, 10, 3, 15, 0, in: seoul)
        #expect(parse("resets Oct 3 at 9am", now: afternoon) == date(2026, 10, 3, 9, 0, in: seoul))
    }

    @Test func unknownZoneFallsBackToParameter() {
        #expect(parse("resets 7pm (Mars/Olympus)") == date(2026, 10, 23, 19, 0, in: seoul))
    }

    @Test func ignoresTextAfterZoneAndUsesLastResets() {
        #expect(parse("resets 1am earlier; limit · resets 6:50pm (Asia/Seoul) try /upgrade") == date(2026, 10, 23, 18, 50, in: seoul))
    }

    @Test func acceptsBulletSeparator() {
        #expect(parse("limit • resets 11:20pm (Asia/Seoul)") == date(2026, 10, 23, 23, 20, in: seoul))
    }

    @Test func rejectsUnparseableMessages() {
        #expect(parse("Rate limit reached") == nil)
        #expect(parse("resets soon") == nil)
        #expect(parse("resets 13pm") == nil)
        #expect(parse("resets 0am") == nil)
        #expect(parse("resets 9:75am") == nil)
        #expect(parse("resets Foo 3 at 9am") == nil)
        #expect(parse("resets Feb 31 at 9am") == nil)
    }

    @Test func fallbackIntervalIsFiveHours() {
        #expect(ClaudeUsageLimitReset.fallbackInterval == 18_000)
    }
}
