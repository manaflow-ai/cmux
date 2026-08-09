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
    func manualUnreadStateControlsWorkspaceActionsWithoutANotificationCount() {
        let workspaceID = UUID()
        let snapshot = SidebarUnreadSnapshot(manualUnreadWorkspaceIds: [workspaceID])

        #expect(snapshot.workspaceIsUnread(forWorkspaceId: workspaceID))
        #expect(snapshot.canMarkWorkspaceRead(forWorkspaceIds: [workspaceID]))
        #expect(!snapshot.canMarkWorkspaceUnread(forWorkspaceIds: [workspaceID]))
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

    @Test
    @MainActor
    func surfaceUnreadProjectionMutatesOnlyItsKeyAndOwnerCount() {
        let existingWorkspaceID = UUID()
        let existingSurfaceID = UUID()
        let dockWindowID = UUID()
        let dockSurfaceID = UUID()
        let existingKey = SidebarSurfaceUnreadKey(
            workspaceId: existingWorkspaceID,
            surfaceId: existingSurfaceID
        )
        let dockKey = SidebarSurfaceUnreadKey(
            workspaceId: dockWindowID,
            surfaceId: dockSurfaceID
        )
        let summary = SidebarWorkspaceUnreadSummary(
            unreadCount: 4,
            latestNotificationText: "Existing notification",
            hasLatestNotification: true
        )
        let focusedReadIndicators = [existingWorkspaceID: existingSurfaceID]
        let manualUnreadWorkspaceIDs: Set<UUID> = [existingWorkspaceID]
        let model = SidebarUnreadModel()
        final class Recorder {
            var snapshots: [SidebarUnreadSnapshot] = []
        }
        let recorder = Recorder()
        let observation = model.observeChanges(owner: recorder) { recorder, snapshot in
            recorder.snapshots.append(snapshot)
        }
        defer { observation.cancel() }

        model.apply(
            totalUnreadCount: 4,
            summaries: [existingWorkspaceID: summary],
            unreadSurfaceKeys: [existingKey],
            focusedReadIndicatorByWorkspaceId: focusedReadIndicators,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIDs
        )
        recorder.snapshots.removeAll()

        model.applySurfaceUnreadProjection(
            dockKey,
            isUnread: true,
            totalUnreadCount: 5
        )

        #expect(recorder.snapshots == [model.snapshot])
        #expect(model.snapshot.totalUnreadCount == 5)
        #expect(model.snapshot.unreadSurfaceKeys == [existingKey])
        #expect(model.unreadSurfaceKeys == [existingKey, dockKey])
        #expect(model.snapshot.summaryByWorkspaceId == [existingWorkspaceID: summary])
        #expect(model.snapshot.focusedReadIndicatorByWorkspaceId == focusedReadIndicators)
        #expect(model.snapshot.manualUnreadWorkspaceIds == manualUnreadWorkspaceIDs)

        model.applySurfaceUnreadProjection(
            dockKey,
            isUnread: true,
            totalUnreadCount: 5
        )
        #expect(recorder.snapshots.count == 1, "An equivalent surface projection must not publish.")

        model.applySurfaceUnreadProjection(
            dockKey,
            isUnread: false,
            totalUnreadCount: 4
        )
        #expect(recorder.snapshots.count == 2)
        #expect(model.unreadSurfaceKeys == [existingKey])
        #expect(model.snapshot.totalUnreadCount == 4)
        #expect(model.snapshot.summaryByWorkspaceId == [existingWorkspaceID: summary])
    }

    @Test
    @MainActor
    func sameOwnerSurfaceMutationDoesNotInvalidateGlobalSnapshot() {
        let ownerID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let model = SidebarUnreadModel()
        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(
                workspaceId: ownerID,
                surfaceId: firstSurfaceID
            ),
            isUnread: true,
            totalUnreadCount: 1
        )

        final class Recorder {
            var snapshots: [SidebarUnreadSnapshot] = []
        }
        let recorder = Recorder()
        let observation = model.observeChanges(owner: recorder) { recorder, snapshot in
            recorder.snapshots.append(snapshot)
        }
        defer { observation.cancel() }

        let invalidationCount = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            invalidationCount.withLock { $0 += 1 }
        }

        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(
                workspaceId: ownerID,
                surfaceId: secondSurfaceID
            ),
            isUnread: true,
            totalUnreadCount: 1
        )

        #expect(invalidationCount.withLock { $0 } == 0)
        #expect(recorder.snapshots.isEmpty)
        #expect(model.hasUnreadNotification(
            forWorkspaceId: ownerID,
            surfaceId: firstSurfaceID
        ))
        #expect(model.hasUnreadNotification(
            forWorkspaceId: ownerID,
            surfaceId: secondSurfaceID
        ))
    }

    @Test
    @MainActor
    func surfaceObserversReceiveOnlyTheirOwnerProjection() {
        let observedOwnerID = UUID()
        let otherOwnerID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let model = SidebarUnreadModel()
        final class Recorder {
            var projections: [SidebarSurfaceUnreadProjection] = []
        }
        let recorder = Recorder()
        let observation = model.observeSurfaceChanges(
            forOwnerId: observedOwnerID,
            owner: recorder
        ) { recorder, projection in
            recorder.projections.append(projection)
        }
        defer { observation.cancel() }

        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(
                workspaceId: otherOwnerID,
                surfaceId: firstSurfaceID
            ),
            isUnread: true,
            totalUnreadCount: 1
        )
        #expect(recorder.projections.isEmpty)

        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(
                workspaceId: observedOwnerID,
                surfaceId: secondSurfaceID
            ),
            isUnread: true,
            totalUnreadCount: 2
        )
        #expect(recorder.projections == [SidebarSurfaceUnreadProjection(
            ownerId: observedOwnerID,
            unreadSurfaceIds: [secondSurfaceID]
        )])
    }

    @Test
    @MainActor
    func summaryObserversIgnoreSurfaceOnlyChanges() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let model = SidebarUnreadModel()
        final class Recorder {
            var snapshots: [SidebarUnreadSnapshot] = []
        }
        let recorder = Recorder()
        let observation = model.observeSummaryChanges(owner: recorder) { recorder, snapshot in
            recorder.snapshots.append(snapshot)
        }
        defer { observation.cancel() }

        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: surfaceID),
            isUnread: true,
            totalUnreadCount: 1
        )
        #expect(recorder.snapshots.isEmpty)

        let summary = SidebarWorkspaceUnreadSummary(
            unreadCount: 1,
            latestNotificationText: nil
        )
        model.applyWorkspaceSummaryProjection(
            forWorkspaceId: workspaceID,
            summary: summary,
            totalUnreadCount: 1
        )
        #expect(recorder.snapshots.map(\.summaryByWorkspaceId) == [[workspaceID: summary]])
    }

    @Test
    @MainActor
    func reentrantPublicationsRemainOrderedForEveryObserver() {
        final class Recorder {
            var totals: [Int] = []
        }
        final class ReentrancyState {
            var didPublishNestedSnapshot = false
        }

        let model = SidebarUnreadModel()
        let first = Recorder()
        let second = Recorder()
        let reentrancy = ReentrancyState()
        let receive: @MainActor (Recorder, SidebarUnreadSnapshot) -> Void = { recorder, snapshot in
            recorder.totals.append(snapshot.totalUnreadCount)
            guard !reentrancy.didPublishNestedSnapshot else { return }
            reentrancy.didPublishNestedSnapshot = true
            model.apply(
                totalUnreadCount: 2,
                summaries: [:],
                unreadSurfaceKeys: [],
                focusedReadIndicatorByWorkspaceId: [:],
                manualUnreadWorkspaceIds: []
            )
        }
        let firstObservation = model.observeChanges(owner: first, receive)
        let secondObservation = model.observeChanges(owner: second, receive)
        defer {
            firstObservation.cancel()
            secondObservation.cancel()
        }

        model.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )

        #expect(first.totals == [1, 2])
        #expect(second.totals == [1, 2])
        #expect(model.snapshot.totalUnreadCount == 2)
    }

    @Test
    @MainActor
    func reentrantSurfacePublicationsRemainOrderedForEveryObserver() {
        final class Recorder {
            var projections: [SidebarSurfaceUnreadProjection] = []
        }
        final class ReentrancyState {
            var didPublishNestedProjection = false
        }

        let ownerID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let model = SidebarUnreadModel()
        let first = Recorder()
        let second = Recorder()
        let reentrancy = ReentrancyState()
        let receive: @MainActor (Recorder, SidebarSurfaceUnreadProjection) -> Void = {
            recorder,
            projection in
            recorder.projections.append(projection)
            guard !reentrancy.didPublishNestedProjection else { return }
            reentrancy.didPublishNestedProjection = true
            model.applySurfaceUnreadProjection(
                SidebarSurfaceUnreadKey(
                    workspaceId: ownerID,
                    surfaceId: secondSurfaceID
                ),
                isUnread: true,
                totalUnreadCount: 1
            )
        }
        let firstObservation = model.observeSurfaceChanges(
            forOwnerId: ownerID,
            owner: first,
            receive
        )
        let secondObservation = model.observeSurfaceChanges(
            forOwnerId: ownerID,
            owner: second,
            receive
        )
        defer {
            firstObservation.cancel()
            secondObservation.cancel()
        }

        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(
                workspaceId: ownerID,
                surfaceId: firstSurfaceID
            ),
            isUnread: true,
            totalUnreadCount: 1
        )

        let expected = [
            SidebarSurfaceUnreadProjection(
                ownerId: ownerID,
                unreadSurfaceIds: [firstSurfaceID]
            ),
            SidebarSurfaceUnreadProjection(
                ownerId: ownerID,
                unreadSurfaceIds: [firstSurfaceID, secondSurfaceID]
            ),
        ]
        #expect(first.projections == expected)
        #expect(second.projections == expected)
    }
}
