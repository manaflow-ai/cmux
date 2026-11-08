import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct NotificationFeedProjectionTests {
    @Test @MainActor func groupsNewestFirstAcrossTodayAndYesterday() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)

        projection.update(items: [
            item(id: "today-newer", createdAt: try #require(isoDate("2026-07-15T17:00:00Z")), isRead: false),
            item(id: "today-older", createdAt: try #require(isoDate("2026-07-15T08:00:00Z")), isRead: true),
            item(id: "yesterday", createdAt: try #require(isoDate("2026-07-14T20:00:00Z")), isRead: false),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        #expect(projection.sections.map(\.kind) == [.today, .yesterday])
        #expect(projection.sections[0].items.map(\.notificationID) == ["today-newer", "today-older"])
        #expect(projection.sections[1].items.map(\.notificationID) == ["yesterday"])
        #expect(projection.sourceItemCount == 3)
        #expect(projection.sourceUnreadCount == 2)
    }

    @Test @MainActor func unreadFilterPreservesChronologyAndStableItems() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(id: "read", createdAt: try #require(isoDate("2026-07-15T17:30:00Z")), isRead: true),
            item(id: "unread", createdAt: try #require(isoDate("2026-07-15T17:00:00Z")), isRead: false),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        projection.filter = .unread
        await projection.waitForPendingRebuild()

        #expect(projection.sections.count == 1)
        #expect(projection.sections[0].items.map(\.notificationID) == ["unread"])
        #expect(projection.sourceItemCount == 2)
        #expect(projection.sourceUnreadCount == 1)
    }

    @Test @MainActor func filterChangeRetainsPriorRowsUntilAsyncRebuildPublishes() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(id: "read", createdAt: try #require(isoDate("2026-07-15T17:30:00Z")), isRead: true),
            item(id: "unread", createdAt: try #require(isoDate("2026-07-15T17:00:00Z")), isRead: false),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["read", "unread"])

        projection.filter = .unread

        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["read", "unread"])
        #expect(projection.isSourceRebuilding)
        #expect(!projection.hasStaleSourceSections)

        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["unread"])
        #expect(!projection.isSourceRebuilding)
        #expect(!projection.hasStaleSourceSections)
    }

    @Test @MainActor func searchMatchesNotificationContentAndComposesWithUnreadFilter() async throws {
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
        await projection.waitForPendingRebuild()

        projection.searchText = "release"
        await projection.waitForPendingRebuild()

        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["tests"])

        projection.filter = .unread
        await projection.waitForPendingRebuild()

        #expect(projection.sections.isEmpty)
        #expect(projection.sourceItemCount == 2)
        #expect(projection.sourceUnreadCount == 1)
    }

    @Test @MainActor func searchChangeRetainsPriorRowsUntilAsyncRebuildPublishes() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(
                id: "approval",
                createdAt: try #require(isoDate("2026-07-15T17:30:00Z")),
                isRead: false,
                title: "Codex needs approval"
            ),
            item(
                id: "tests",
                createdAt: try #require(isoDate("2026-07-15T17:00:00Z")),
                isRead: false,
                title: "Tests passed"
            ),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["approval", "tests"])

        projection.searchText = "tests"

        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["approval", "tests"])
        #expect(projection.isSourceRebuilding)
        #expect(!projection.hasStaleSourceSections)

        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["tests"])
        #expect(!projection.isSourceRebuilding)
        #expect(!projection.hasStaleSourceSections)
    }

    @Test @MainActor func searchMatchesMetadataAfterLongBody() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(
                id: "metadata",
                createdAt: try #require(isoDate("2026-07-15T17:30:00Z")),
                isRead: false,
                title: "Long notification",
                body: String(repeating: "noise ", count: 2_000),
                workspaceTitle: "Workspace Search Target",
                surfaceTitle: "Agent Pane",
                macDisplayName: "Studio"
            ),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        projection.searchText = "search target"
        await projection.waitForPendingRebuild()

        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["metadata"])
    }

    @Test @MainActor func rapidSearchPublishesOnlyTheLatestProjection() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(
                id: "first",
                createdAt: try #require(isoDate("2026-07-15T17:30:00Z")),
                isRead: false,
                title: "First result"
            ),
            item(
                id: "latest",
                createdAt: try #require(isoDate("2026-07-15T17:00:00Z")),
                isRead: false,
                title: "Latest result"
            ),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        projection.searchText = "first"
        projection.searchText = "latest"
        await projection.waitForPendingRebuild()

        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["latest"])
    }

    @Test @MainActor func searchTextIsBoundedByScalarsAndBytesBeforeRebuild() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(
                id: "target",
                createdAt: try #require(isoDate("2026-07-15T17:30:00Z")),
                isRead: false,
                title: "Target"
            ),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        projection.searchText = "target" + String(repeating: "\u{0301}", count: 10_000)

        #expect(projection.searchText.unicodeScalars.count <= notificationFeedProjectionMaxSearchQueryUnicodeScalars)
        #expect(projection.searchText.utf8.count <= notificationFeedProjectionMaxSearchQueryUTF8Bytes)
        await projection.waitForPendingRebuild()
        #expect(!projection.isSourceRebuilding)
    }

    @Test @MainActor func searchTextPreservesTrailingSpaceWhileFilteringWithTrimmedQuery() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(
                id: "docs",
                createdAt: try #require(isoDate("2026-07-15T17:30:00Z")),
                isRead: false,
                title: "Docs"
            ),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        projection.searchText = "Docs "
        await projection.waitForPendingRebuild()

        #expect(projection.searchText == "Docs ")
        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["docs"])
    }

    @Test @MainActor func sourceUpdateCapsInputBeforeSearchWork() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        let cap = notificationFeedProjectionMaxSourceItemCount
        let total = cap + 25
        let items = (0..<total).map { offset in
            item(
                id: "row-\(offset)",
                createdAt: referenceDate.addingTimeInterval(Double(total - offset)),
                isRead: false,
                title: offset == cap + 10 ? "Dropped search target" : "Noise \(offset)"
            )
        }

        projection.update(items: items, referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        #expect(projection.sourceItemCount == cap)
        #expect(projection.sourceUnreadCount == cap)
        #expect(
            projection.sections.flatMap(\.items).count
                == min(cap, notificationFeedProjectionInitialRowWindow)
        )
        #expect(projection.hasMoreRows == (cap > notificationFeedProjectionInitialRowWindow))

        projection.searchText = "Dropped search target"
        await projection.waitForPendingRebuild()

        #expect(projection.sections.isEmpty)
        #expect(!projection.isSourceRebuilding)
    }

    @Test @MainActor func rowWindowMountsIncrementallyAndSurvivesSourceUpdates() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        let window = notificationFeedProjectionInitialRowWindow
        let total = window + 40
        func makeItems(firstIsRead: Bool) -> [MobileNotificationFeedItem] {
            (0..<total).map { offset in
                item(
                    id: "row-\(offset)",
                    createdAt: referenceDate.addingTimeInterval(Double(-offset)),
                    isRead: offset == 0 ? firstIsRead : false
                )
            }
        }

        projection.update(items: makeItems(firstIsRead: false), referenceDate: referenceDate)
        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).count == window)
        #expect(projection.hasMoreRows)

        projection.extendRowWindow()
        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).count == total)
        #expect(!projection.hasMoreRows)

        // A source refresh (same shape, one row's read state flipped) must not
        // collapse how far the user has already scrolled.
        projection.update(items: makeItems(firstIsRead: true), referenceDate: referenceDate)
        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).count == total)
        #expect(!projection.hasMoreRows)

        // Filter changes reset the window to the initial mount.
        projection.filter = .unread
        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).count == window)
        #expect(projection.hasMoreRows)
    }

    @Test @MainActor func sourceUpdateRetainsButMarksPriorRowsStaleUntilAsyncRebuildPublishes() async throws {
        let referenceDate = try #require(isoDate("2026-07-15T18:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: [
            item(
                id: "old-scope",
                createdAt: try #require(isoDate("2026-07-15T17:30:00Z")),
                isRead: false
            ),
        ], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["old-scope"])

        projection.update(items: [
            item(
                id: "new-scope",
                createdAt: try #require(isoDate("2026-07-15T17:00:00Z")),
                isRead: false
            ),
        ], referenceDate: referenceDate)

        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["old-scope"])
        #expect(projection.isSourceRebuilding)
        #expect(projection.hasStaleSourceSections)

        await projection.waitForPendingRebuild()
        #expect(projection.sections.flatMap(\.items).map(\.notificationID) == ["new-scope"])
        #expect(!projection.isSourceRebuilding)
        #expect(!projection.hasStaleSourceSections)
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
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            hasSearchQuery: true,
            status: .loading
        ) == .loading)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            hasSearchQuery: true,
            status: .unavailable
        ) == .unavailable)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 2,
            filter: .all,
            hasSearchQuery: true,
            status: .unavailable
        ) == .noSearchResults)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            hasSearchQuery: true,
            status: .requiresMacUpdate
        ) == .requiresMacUpdate)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 2,
            filter: .all,
            hasSearchQuery: true,
            status: .requiresMacUpdate
        ) == .noSearchResults)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 2,
            filter: .unread,
            status: .unavailable
        ) == .allRead)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 2,
            filter: .unread,
            status: .requiresMacUpdate
        ) == .allRead)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            hasSearchQuery: true,
            isSourceRebuilding: true,
            status: .ready
        ) == .loading)
        #expect(NotificationFeedEmptyState.resolve(
            sourceItemCount: 0,
            filter: .all,
            hasSearchQuery: true,
            status: .ready
        ) == .noSearchResults)
    }
    #endif

    private func item(
        id: String,
        createdAt: Date,
        isRead: Bool,
        title: String? = nil,
        body: String = "Body",
        workspaceTitle: String = "Workspace",
        surfaceTitle: String = "Terminal",
        macDisplayName: String = "Mac"
    ) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            macDeviceID: id == "yesterday" ? "mac-b" : "mac-a",
            notificationID: id,
            macDisplayName: macDisplayName,
            remoteWorkspaceID: "workspace",
            remoteSurfaceID: "surface",
            title: title ?? id,
            body: body,
            createdAt: createdAt,
            isRead: isRead,
            workspaceTitle: workspaceTitle,
            surfaceTitle: surfaceTitle,
            connectionStatus: .connected
        )
    }

    private func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
