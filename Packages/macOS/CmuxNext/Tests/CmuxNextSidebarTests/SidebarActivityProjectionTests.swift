import Foundation
import Testing
@testable import CmuxNextSidebar

/// Activity view (meeting 2026-10-08, AV): a Priority section of the chats
/// that need the person, then every chat by day.
@Suite struct SidebarActivityProjectionTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    /// Wednesday 2026-10-07 15:00 in Los Angeles.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15))!

    private func chat(_ id: String, hoursAgo: Double, _ attention: SidebarActivityAttention? = nil) -> SidebarActivityChat {
        SidebarActivityChat(id: id, title: id, harness: "codex", updatedAt: Self.now.addingTimeInterval(-hoursAgo * 3600),
                            attention: attention, preview: "latest from \(id)")
    }

    private func project(_ chats: [SidebarActivityChat]) -> SidebarActivityProjection {
        SidebarActivityProjection(chats: chats, now: Self.now, calendar: Self.calendar)
    }

    @Test func priorityListsChatsNeedingThePersonMostUrgentFirst() {
        let projection = project([
            chat("quiet", hoursAgo: 0.1),
            chat("unread-new", hoursAgo: 0.5, .unread),
            chat("failed", hoursAgo: 3, .failed),
            chat("asks", hoursAgo: 5, .needsInput),
            chat("unread-old", hoursAgo: 30, .unread),
        ])
        #expect(projection.priority.map(\.id) == ["asks", "failed", "unread-new", "unread-old"])
    }

    @Test func everyChatIsGroupedByDayNewestFirst() {
        let projection = project([
            chat("old", hoursAgo: 24 * 20),
            chat("this-morning", hoursAgo: 6),
            chat("last-night", hoursAgo: 18),
            chat("monday", hoursAgo: 50),
            chat("just-now", hoursAgo: 0.2, .unread),
        ])
        #expect(projection.groups.map(\.bucket) == [.today, .yesterday, .thisWeek, .older])
        #expect(projection.groups.map { $0.chats.map(\.id) } == [["just-now", "this-morning"], ["last-night"], ["monday"], ["old"]])
    }

    @Test func emptyDaysAreLeftOutAndAFutureTimeCountsAsToday() {
        let projection = project([chat("skewed", hoursAgo: -2), chat("ancient", hoursAgo: 24 * 400)])
        #expect(projection.groups.map(\.bucket) == [.today, .older])
        #expect(project([]).priority.isEmpty && project([]).groups.isEmpty)
    }

    /// For random chat lists: each chat sits in exactly one day group, the
    /// one its time falls in; groups come in day order, each newest first;
    /// Priority is exactly the chats with attention.
    @Test(arguments: 0..<200) func groupingKeepsEveryChatOnceInItsDay(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let attentions: [SidebarActivityAttention?] = [nil, nil, nil] + SidebarActivityAttention.allCases.map { $0 }
        let chats = (0..<Int.random(in: 0...30, using: &generator)).map { index in
            chat("c\(index)", hoursAgo: Double.random(in: -3...(24 * 40), using: &generator),
                 attentions.randomElement(using: &generator)!)
        }
        let projection = project(chats)
        let grouped = projection.groups.flatMap(\.chats)
        #expect(grouped.map(\.id).sorted() == chats.map(\.id).sorted())
        #expect(projection.groups.map(\.bucket) == SidebarActivityBucket.allCases.filter { bucket in projection.groups.contains { $0.bucket == bucket } })
        for group in projection.groups {
            #expect(group.chats.map(\.updatedAt) == group.chats.map(\.updatedAt).sorted(by: >))
            for chat in group.chats {
                #expect(SidebarActivityBucket.of(chat.updatedAt, now: Self.now, calendar: Self.calendar) == group.bucket)
            }
        }
        #expect(Set(projection.priority.map(\.id)) == Set(chats.filter { $0.attention != nil }.map(\.id)))
        #expect(zip(projection.priority, projection.priority.dropFirst()).allSatisfy { earlier, later in
            earlier.attention! < later.attention! || (earlier.attention == later.attention && earlier.updatedAt >= later.updatedAt)
        })
    }

    @Test func dayBoundariesFollowTheCalendar() {
        let startOfToday = Self.calendar.startOfDay(for: Self.now)
        let bucket = { (date: Date) in SidebarActivityBucket.of(date, now: Self.now, calendar: Self.calendar) }
        #expect(bucket(startOfToday) == .today)
        #expect(bucket(startOfToday.addingTimeInterval(-1)) == .yesterday)
        #expect(bucket(startOfToday.addingTimeInterval(-86_400)) == .yesterday)
        #expect(bucket(startOfToday.addingTimeInterval(-86_401)) == .thisWeek)
        #expect(bucket(startOfToday.addingTimeInterval(-6 * 86_400)) == .thisWeek)
        #expect(bucket(startOfToday.addingTimeInterval(-6 * 86_400 - 1)) == .older)
    }
}
