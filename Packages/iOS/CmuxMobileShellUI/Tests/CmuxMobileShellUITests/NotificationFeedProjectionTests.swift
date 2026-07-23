import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct NotificationFeedProjectionTests {
    @Test @MainActor func groupsNewestFirstAcrossTodayAndYesterday() throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)

        projection.update(items: [
            item(id: "yesterday", createdAt: try #require(isoDate("2026-07-14T20:00:00Z")), isRead: false),
            item(id: "today-older", createdAt: try #require(isoDate("2026-07-15T08:00:00Z")), isRead: true),
            item(id: "today-newer", createdAt: try #require(isoDate("2026-07-15T17:00:00Z")), isRead: false),
        ], referenceDate: referenceDate)

        #expect(projection.sections.map(\.kind) == [.today, .yesterday])
        #expect(projection.sections[0].items.map(\.notificationID) == ["today-newer", "today-older"])
        #expect(projection.sections[1].items.map(\.notificationID) == ["yesterday"])
        #expect(projection.sourceItemCount == 3)
        #expect(projection.sourceUnreadCount == 2)
    }

    @Test @MainActor func unreadFilterPreservesChronologyAndStableItems() throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(id: "read", createdAt: try #require(isoDate("2026-07-15T17:30:00Z")), isRead: true),
            item(id: "unread", createdAt: try #require(isoDate("2026-07-15T17:00:00Z")), isRead: false),
        ], referenceDate: referenceDate)

        projection.filter = .unread

        #expect(projection.sections.count == 1)
        #expect(projection.sections[0].items.map(\.notificationID) == ["unread"])
        #expect(projection.sourceItemCount == 2)
        #expect(projection.sourceUnreadCount == 1)
    }

    @Test @MainActor func searchMatchesNotificationContentAndComposesWithUnreadFilter() throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(
                id: "approval",
                createdAt: try #require(isoDate("2026-07-15T17:30:00Z")),
                isRead: false,
                title: "Codex needs approval",
                body: "Review the workspace changes"
            ),
            item(
                id: "tests",
                createdAt: try #require(isoDate("2026-07-15T17:00:00Z")),
                isRead: true,
                title: "Tests passed",
                body: "Release is ready"
            ),
        ], referenceDate: referenceDate)

        projection.searchText = "release"

        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["tests"])

        projection.filter = .unread

        #expect(projection.sections.isEmpty)
        #expect(projection.sourceItemCount == 2)
        #expect(projection.sourceUnreadCount == 1)
    }

    #if os(iOS)
    @Test func emptyPresentationDistinguishesFilterAndAvailability() {
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 2,
            filter: .unread,
            status: .ready
        ) == .allRead)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            status: .loading
        ) == .loading)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            status: .unavailable
        ) == .unavailable)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            status: .requiresMacUpdate
        ) == .requiresMacUpdate)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            status: .ready
        ) == .empty)
    }
    #endif

    private func item(
        id: String,
        createdAt: Date,
        isRead: Bool,
        title: String? = nil,
        body: String = "Body"
    ) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            macDeviceID: id == "yesterday" ? "mac-b" : "mac-a",
            notificationID: id,
            macDisplayName: "Mac",
            remoteWorkspaceID: "workspace",
            remoteSurfaceID: "surface",
            title: title ?? id,
            body: body,
            createdAt: createdAt,
            isRead: isRead,
            workspaceTitle: "Workspace",
            surfaceTitle: "Terminal",
            connectionStatus: .connected
        )
    }

    private func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
