import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct NotificationFeedHistoryTests {
    @Test @MainActor func expansionMountsOriginalNotificationsAsIndependentRows() async throws {
        let latest = item("latest", age: 0)
        let older = item("older", age: 60, isRead: true)
        let projection = await makeProjection(for: [latest, older])
        let section = try #require(projection.sections.first)
        #expect(section.rows.map(\.id) == [latest.id])
        #expect(section.rows[0].model == NotificationFeedRowModel(item: latest))
        #expect(section.rows[0].context == .standalone)

        let groupID = try #require(section.rows[0].disclosure?.groupID)
        projection.toggleGroup(groupID)
        let rows = try #require(projection.sections.first).rows
        #expect(rows.map(\.id) == [latest.id, older.id])
        #expect(rows[1].model.item == older)
        #expect(rows[1].context.isNested)
        #expect(rows[1].context.hidesHeadline)
        #expect(rows[1].context.hidesSource)
        #expect(rows[1].context.hidesComputer)
        #expect(rows[1].disclosure == nil)
        #expect(rows[0].disclosure?.isExpanded == true)

        projection.toggleGroup(groupID)
        #expect(projection.sections[0].rows.map(\.id) == [latest.id])
    }

    @Test @MainActor func aNewLatestNotificationPreservesExpandedHistory() async throws {
        let latest = item("latest", age: 60)
        let oldest = item("oldest", age: 120)
        let projection = await makeProjection(for: [latest, oldest])
        let groupID = try #require(projection.sections.first?.rows.first?.disclosure?.groupID)
        projection.toggleGroup(groupID)

        let incoming = item("incoming", age: 0)
        projection.update(items: [incoming, latest, oldest], referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        let rows = try #require(projection.sections.first).rows
        #expect(rows.map(\.id) == [incoming.id, latest.id, oldest.id])
        #expect(rows[0].disclosure?.groupID == groupID)
        #expect(rows[0].disclosure?.isExpanded == true)
        #expect(rows[1].context.isNested)
    }

    @Test @MainActor func loadingMoreHistoryPreservesTheExpandedGroupIdentity() async throws {
        let items = (0...notificationFeedProjectionInitialRowWindow).map {
            item("event-\($0)", age: TimeInterval($0))
        }
        let projection = await makeProjection(for: items)
        let groupID = try #require(projection.sections.first?.rows.first?.disclosure?.groupID)
        projection.toggleGroup(groupID)
        #expect(projection.hasMoreRows)

        projection.extendRowWindow()
        await projection.waitForPendingRebuild()

        let rows = try #require(projection.sections.first).rows
        #expect(rows.count == items.count)
        #expect(rows.first?.disclosure?.groupID == groupID)
        #expect(rows.first?.disclosure?.isExpanded == true)
        #expect(rows.last?.id == items.last?.id)
        #expect(!projection.hasMoreRows)
    }

    @Test @MainActor func pruningTheExpandedAnchorPreservesSurvivingHistory() async throws {
        let limit = notificationFeedProjectionMaxSourceItemCount
        let items = (0..<limit).map {
            item("event-\($0)", age: TimeInterval($0), workspace: $0 < limit - 3 ? "other" : "workspace")
        }
        let projection = await makeProjection(for: items)
        for _ in stride(
            from: notificationFeedProjectionInitialRowWindow,
            to: limit,
            by: notificationFeedProjectionRowWindowIncrement
        ) {
            projection.extendRowWindow()
            await projection.waitForPendingRebuild()
        }
        #expect(!projection.hasMoreRows)
        let groupID = try #require(projection.sections.first?.rows.last?.disclosure?.groupID)
        #expect(groupID == items.last?.id)
        projection.toggleGroup(groupID)

        let incoming = item("incoming", age: -1, workspace: "other")
        projection.update(items: [incoming] + items, referenceDate: referenceDate)
        await projection.waitForPendingRebuild()

        let rows = try #require(projection.sections.first).rows
        #expect(projection.sourceItemCount == limit)
        #expect(rows.map(\.id) == [incoming.id, items[limit - 3].id, items[limit - 2].id])
        #expect(rows[1].disclosure?.isExpanded == true)
        #expect(rows.last?.context.isNested == true)
        let survivingGroupID = try #require(rows[1].disclosure?.groupID)
        projection.toggleGroup(survivingGroupID)
        #expect(projection.sections[0].rows.map(\.id) == [incoming.id, items[limit - 3].id])
    }

    @Test func nestedRowsPreserveUniqueTitlesIncludingTitleOnlyNotifications() throws {
        let latest = NotificationFeedRowModel(item: item("latest", age: 0))
        let titleOnly = NotificationFeedRowModel(item: item(
            "title-only", age: 60, title: "Tests passed", body: ""
        ))
        let group = try #require(NotificationFeedActivityGroup.build(from: [latest, titleOnly]).first)
        let rows = group.rows(isExpanded: true)
        #expect(rows[1].context.hidesHeadline)
        #expect(rows[1].context.hidesComputer)
        #expect(!rows[1].context.hidesSource)
        #expect(rows[1].model.presentation.sourceName == "Tests passed")
    }

    @Test func inheritedMetadataUsesTheSameNormalizationAsOrdinaryRows() {
        let latest = NotificationFeedRowPresentation(item: item("latest", age: 0, title: "Résumé Review"))
        let older = NotificationFeedRowPresentation(item: item("older", age: 60, title: " resume  review "))
        #expect(older.nestedContext(under: latest).hidesSource)
    }

    @Test func groupingKeepsDifferentWorkspacesComputersAndSurfacesSeparate() {
        let items = [
            item("a", age: 0),
            item("b", age: 30, workspace: "other"),
            item("c", age: 60, mac: "other-mac"),
            item("d", age: 90, surface: "other-surface"),
        ]
        #expect(NotificationFeedActivityGroup.build(from: items.map(NotificationFeedRowModel.init)).count == 4)
    }

    @Test func groupingRetainsTheExistingTwoHourBoundary() {
        let items = [item("latest", age: 0), item("older", age: 7_201)]
        #expect(NotificationFeedActivityGroup.build(from: items.map(NotificationFeedRowModel.init)).count == 2)
    }

    @MainActor private func makeProjection(for items: [MobileNotificationFeedItem]) async -> NotificationFeedProjection {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let projection = NotificationFeedProjection(referenceDate: referenceDate, calendar: calendar)
        projection.update(items: items, referenceDate: referenceDate)
        await projection.waitForPendingRebuild()
        return projection
    }

    private var referenceDate: Date { Date(timeIntervalSince1970: 1_788_544_800) }

    private func item(
        _ id: String, age: TimeInterval, isRead: Bool = false,
        title: String = "Codex", body: String = "Notification content",
        workspace: String = "workspace", mac: String = "mac", surface: String = "surface"
    ) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            macDeviceID: mac,
            notificationID: id,
            macDisplayName: "MacBook Pro",
            remoteWorkspaceID: workspace,
            remoteSurfaceID: surface,
            title: title,
            body: body,
            createdAt: referenceDate.addingTimeInterval(-age),
            isRead: isRead,
            workspaceTitle: "cmux iOS",
            surfaceTitle: "Terminal",
            connectionStatus: .connected
        )
    }
}
