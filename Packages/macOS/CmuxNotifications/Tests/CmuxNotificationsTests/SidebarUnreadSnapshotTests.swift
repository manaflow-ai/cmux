import Foundation
import Testing
@testable import CmuxNotifications

@Suite("Sidebar unread snapshot")
struct SidebarUnreadSnapshotTests {
    @Test
    func queriesResolveMissingAndSurfaceState() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = SidebarUnreadSnapshot(
            totalUnreadCount: 2,
            summaryByWorkspaceId: [
                workspaceID: SidebarWorkspaceUnreadSummary(
                    unreadCount: 2,
                    latestNotificationText: "Pi finished",
                    hasLatestNotification: true
                ),
            ],
            unreadSurfaceKeys: [
                SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: surfaceID),
            ],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: [workspaceID]
        )

        #expect(snapshot.totalUnreadCount == 2)
        #expect(snapshot.unreadCount(forWorkspaceId: workspaceID) == 2)
        #expect(snapshot.latestNotificationText(forWorkspaceId: workspaceID) == "Pi finished")
        #expect(snapshot.hasManualUnread(forWorkspaceId: workspaceID))
        #expect(snapshot.hasVisibleNotificationIndicator(
            forWorkspaceId: workspaceID,
            surfaceId: surfaceID
        ))
        #expect(snapshot.summary(forWorkspaceId: UUID()).unreadCount == 0)
    }

    @Test
    @MainActor
    func modelStreamsOnlyChangedAtomicSnapshots() async {
        let workspaceID = UUID()
        let model = SidebarUnreadModel()
        var iterator = model.snapshotChanges().makeAsyncIterator()

        model.apply(
            totalUnreadCount: 1,
            summaries: [
                workspaceID: SidebarWorkspaceUnreadSummary(
                    unreadCount: 1,
                    latestNotificationText: "Pi finished"
                ),
            ],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        let first = await iterator.next()
        #expect(first == model.snapshot)

        var nextIterator = model.snapshotChanges().makeAsyncIterator()
        model.apply(
            totalUnreadCount: 1,
            summaries: [
                workspaceID: SidebarWorkspaceUnreadSummary(
                    unreadCount: 1,
                    latestNotificationText: "Pi finished"
                ),
            ],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        model.apply(
            totalUnreadCount: 0,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        let second = await nextIterator.next()
        #expect(second?.totalUnreadCount == 0)
        #expect(second?.summaryByWorkspaceId.isEmpty == true)
    }
}
