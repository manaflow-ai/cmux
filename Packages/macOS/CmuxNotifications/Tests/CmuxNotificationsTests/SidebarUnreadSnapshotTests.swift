import Foundation
import Observation
import os
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
    func modelPublishesOnlyChangedAtomicSnapshots() {
        let workspaceID = UUID()
        let model = SidebarUnreadModel()
        final class Recorder {
            var snapshots: [SidebarUnreadSnapshot] = []
        }
        let recorder = Recorder()
        let observation = model.observeChanges(owner: recorder) { recorder, snapshot in
            recorder.snapshots.append(snapshot)
        }

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
        #expect(recorder.snapshots == [model.snapshot])

        let publicationCount = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            publicationCount.withLock { $0 += 1 }
        }
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
        #expect(
            publicationCount.withLock { $0 } == 0,
            "An equivalent snapshot must not publish."
        )

        model.apply(
            totalUnreadCount: 0,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        #expect(recorder.snapshots.count == 2)
        #expect(recorder.snapshots.last?.totalUnreadCount == 0)
        #expect(recorder.snapshots.last?.summaryByWorkspaceId.isEmpty == true)

        observation.cancel()
        model.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        #expect(recorder.snapshots.count == 2)
    }
}
