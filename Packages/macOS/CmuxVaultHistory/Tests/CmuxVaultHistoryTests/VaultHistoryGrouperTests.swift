import Foundation
import Testing

@testable import CmuxVaultHistory

@Suite struct VaultHistoryGrouperTests {
    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private static let now = Date(timeIntervalSince1970: 1_781_784_000)

    private func event(
        id: String,
        secondsAgo: TimeInterval,
        kind: VaultHistoryEventKind = .workspaceCreated,
        title: String = "",
        workspaceId: UUID? = nil,
        windowId: UUID? = nil,
        agent: String? = nil
    ) -> VaultHistoryEvent {
        VaultHistoryEvent(
            id: id,
            timestamp: Self.now.addingTimeInterval(-secondsAgo),
            kind: kind,
            title: title,
            subject: VaultHistorySubject(
                workspaceId: workspaceId,
                windowId: windowId,
                sessionId: agent == nil ? nil : "session-\(id)",
                agent: agent
            )
        )
    }

    @Test func dateBucketBoundariesAroundLast24Hours() {
        let calendar = Self.utcCalendar()
        let justInside = Self.now.addingTimeInterval(-24 * 3_600 + 60)
        let justOutside = Self.now.addingTimeInterval(-24 * 3_600 - 60)

        #expect(VaultHistoryDateBucket.bucket(
            for: justInside,
            now: Self.now,
            calendar: calendar
        ) == .last24Hours)
        #expect(VaultHistoryDateBucket.bucket(
            for: justOutside,
            now: Self.now,
            calendar: calendar
        ) == .yesterday)
    }

    @Test func dateBucketCalendarBoundaries() {
        let calendar = Self.utcCalendar()
        let sameWeek = Date(timeIntervalSince1970: 1_781_596_800)
        let sameMonth = Date(timeIntervalSince1970: 1_780_704_000)
        let older = Date(timeIntervalSince1970: 1_779_105_600)

        #expect(VaultHistoryDateBucket.bucket(
            for: sameWeek,
            now: Self.now,
            calendar: calendar
        ) == .thisWeek)
        #expect(VaultHistoryDateBucket.bucket(
            for: sameMonth,
            now: Self.now,
            calendar: calendar
        ) == .thisMonth)
        #expect(VaultHistoryDateBucket.bucket(
            for: older,
            now: Self.now,
            calendar: calendar
        ) == .older)
    }

    @Test func dateGroupingOrdersBucketsAndSkipsEmptyBuckets() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let groups = grouper.groups(events: [
            event(id: "older", secondsAgo: 40 * 24 * 3_600),
            event(id: "recent", secondsAgo: 600),
            event(id: "yesterday", secondsAgo: 25 * 3_600),
        ], by: .date, now: Self.now)

        #expect(groups.map(\.id) == [
            "date:\(VaultHistoryDateBucket.last24Hours.rawValue)",
            "date:\(VaultHistoryDateBucket.yesterday.rawValue)",
            "date:\(VaultHistoryDateBucket.older.rawValue)",
        ])
        #expect(groups.map { $0.events.map(\.id) } == [
            ["recent"],
            ["yesterday"],
            ["older"],
        ])
    }

    @Test func workspaceGroupingClustersByIdentityAndKeepsOtherLast() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let workspaceA = UUID()
        let workspaceB = UUID()
        let groups = grouper.groups(events: [
            event(id: "a-old", secondsAgo: 500, title: "Old", workspaceId: workspaceA),
            event(id: "b-only", secondsAgo: 100, title: "Beta", workspaceId: workspaceB),
            event(id: "a-new", secondsAgo: 50, kind: .workspaceRenamed, title: "New", workspaceId: workspaceA),
            event(id: "other", secondsAgo: 10, kind: .windowOpened),
        ], by: .workspace, now: Self.now)

        #expect(groups.map(\.id) == [
            "workspace:\(workspaceA.uuidString)",
            "workspace:\(workspaceB.uuidString)",
            VaultHistoryGrouper.otherGroupID,
        ])
        #expect(groups[0].events.map(\.id) == ["a-new", "a-old"])
        #expect(groups[2].events.map(\.id) == ["other"])
    }

    @Test func windowAgentAndKindGroupingUseOneGenericPass() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let window = UUID()
        let events = [
            event(id: "window", secondsAgo: 30, kind: .windowOpened, windowId: window),
            event(id: "codex", secondsAgo: 20, kind: .sessionActivity, agent: "codex"),
            event(id: "claude", secondsAgo: 10, kind: .sessionActivity, agent: "claude"),
        ]

        #expect(grouper.groups(events: events, by: .window, now: Self.now).map(\.id) == [
            "window:\(window.uuidString)",
            VaultHistoryGrouper.otherGroupID,
        ])
        #expect(grouper.groups(events: events, by: .agent, now: Self.now).map(\.id) == [
            "agent:claude",
            "agent:codex",
            VaultHistoryGrouper.otherGroupID,
        ])
        #expect(grouper.groups(events: events, by: .kind, now: Self.now).map(\.id) == [
            "kind:sessionActivity",
            "kind:windowOpened",
        ])
    }

    @Test func preorderedGroupingMatchesTheSortingEntryPoint() {
        let grouper = VaultHistoryGrouper(calendar: Self.utcCalendar())
        let events = [
            event(id: "old", secondsAgo: 60),
            event(id: "new", secondsAgo: 10),
            event(id: "middle", secondsAgo: 30),
        ]
        let newestFirst = events.sorted(by: VaultHistoryEvent.newestFirst)

        #expect(
            grouper.groups(newestFirstEvents: newestFirst, by: .date, now: Self.now)
                == grouper.groups(events: events, by: .date, now: Self.now)
        )
    }

    @Test func newestFirstMergeIsLinearOrderedAndBounded() {
        let lhs = [
            event(id: "tie-a", secondsAgo: 10),
            event(id: "old", secondsAgo: 60),
        ].sorted(by: VaultHistoryEvent.newestFirst)
        let rhs = [
            event(id: "tie-z", secondsAgo: 10),
            event(id: "middle", secondsAgo: 30),
        ].sorted(by: VaultHistoryEvent.newestFirst)

        #expect(
            VaultHistoryEvent.mergeNewestFirst(lhs, rhs, limit: 3).map(\.id)
                == ["tie-z", "tie-a", "middle"]
        )
        #expect(VaultHistoryEvent.mergeNewestFirst(lhs, rhs, limit: 0).isEmpty)
    }
}
