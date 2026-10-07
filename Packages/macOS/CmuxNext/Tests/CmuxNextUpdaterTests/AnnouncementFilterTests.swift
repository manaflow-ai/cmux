import Foundation
import Testing
@testable import CmuxNextUpdater

/// R114 announcements: build range, time window, dismissals, at most three.
@Suite struct AnnouncementFilterTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!

    @Test func dismissedExpiredFutureAndOutOfRangeCardsHide() {
        let all = [
            Announcement(id: "a", title: "A"),
            Announcement(id: "gone", title: "Dismissed"),
            Announcement(id: "old", title: "Expired", expiresAt: "2026-10-01T00:00:00Z"),
            Announcement(id: "soon", title: "Later", startsAt: "2026-10-06T00:00:00Z"),
            Announcement(id: "new", title: "Needs newer", minBuild: "11"),
            Announcement(id: "range", title: "In range", minBuild: "9", maxBuild: "10"),
        ]
        let shown = AnnouncementFilter.visible(all, build: "10", now: now, dismissed: ["gone"])
        #expect(shown.map(\.id) == ["a", "range"])
    }

    @Test func atMostThreeInFeedOrder() {
        let all = (1...5).map { Announcement(id: "\($0)", title: "\($0)") }
        #expect(AnnouncementFilter.visible(all, build: "1", now: now, dismissed: []).map(\.id) == ["1", "2", "3"])
    }

    @Test func aBadDateHidesTheCard() {
        let all = [Announcement(id: "bad", title: "Bad", expiresAt: "tomorrow")]
        #expect(AnnouncementFilter.visible(all, build: "1", now: now, dismissed: []).isEmpty)
    }
}
