import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct NotificationFeedDayGroupingTests {
    @Test func groupsAcrossMidnightYesterdayAndOlder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 0, minute: 5)))
        let items = [
            ("today", now.addingTimeInterval(-60)),
            ("yesterday", now.addingTimeInterval(-600)),
            ("older", now.addingTimeInterval(-90_000)),
        ]
        let sections = NotificationFeedDayGrouping(now: now, calendar: calendar)
            .sections(for: items, createdAt: { $0.1 })
        #expect(sections.count == 3)
        #expect(sections[0].day == .today)
        #expect(sections[1].day == .yesterday)
        if case .older = sections[2].day {} else { Issue.record("Expected older section") }
        #expect(sections.map { $0.items.map(\.0) } == [["today"], ["yesterday"], ["older"]])
    }
}
