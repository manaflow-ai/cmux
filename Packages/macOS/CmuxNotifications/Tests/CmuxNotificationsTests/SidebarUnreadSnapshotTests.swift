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
        let recorder = SidebarUnreadValueRecorder<SidebarUnreadSnapshot>()
        let observation = model.observeChanges(owner: recorder) { recorder, snapshot in
            recorder.values.append(snapshot)
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
        #expect(recorder.values == [model.snapshot])

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
        #expect(recorder.values.count == 2)
        #expect(recorder.values.last?.totalUnreadCount == 0)
        #expect(recorder.values.last?.summaryByWorkspaceId.isEmpty == true)

        observation.cancel()
        model.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        #expect(recorder.values.count == 2)
    }

    @Test
    @MainActor
    func releasingObservationSynchronouslyStopsDelivery() {
        let model = SidebarUnreadModel()
        let recorder = SidebarUnreadValueRecorder<SidebarUnreadSnapshot>()
        var observation: SidebarUnreadObservation? = model.observeChanges(
            owner: recorder
        ) { recorder, snapshot in
            recorder.values.append(snapshot)
        }
        #expect(observation != nil)

        observation = nil
        model.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )

        #expect(recorder.values.isEmpty)
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
        let recorder = SidebarUnreadValueRecorder<SidebarUnreadSnapshot>()
        let observation = model.observeChanges(owner: recorder) { recorder, snapshot in
            recorder.values.append(snapshot)
        }
        defer { observation.cancel() }

        model.apply(
            totalUnreadCount: 4,
            summaries: [existingWorkspaceID: summary],
            unreadSurfaceKeys: [existingKey],
            focusedReadIndicatorByWorkspaceId: focusedReadIndicators,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIDs
        )
        recorder.values.removeAll()

        model.applySurfaceUnreadProjection(
            dockKey,
            isUnread: true,
            totalUnreadCount: 5
        )

        #expect(recorder.values == [model.snapshot])
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
        #expect(recorder.values.count == 1, "An equivalent surface projection must not publish.")

        model.applySurfaceUnreadProjection(
            dockKey,
            isUnread: false,
            totalUnreadCount: 4
        )
        #expect(recorder.values.count == 2)
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

        let recorder = SidebarUnreadValueRecorder<SidebarUnreadSnapshot>()
        let observation = model.observeChanges(owner: recorder) { recorder, snapshot in
            recorder.values.append(snapshot)
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
        #expect(recorder.values.isEmpty)
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
        let recorder = SidebarUnreadValueRecorder<SidebarSurfaceUnreadProjection>()
        let observation = model.observeSurfaceChanges(
            forOwnerId: observedOwnerID,
            owner: recorder
        ) { recorder, projection in
            recorder.values.append(projection)
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
        #expect(recorder.values.isEmpty)

        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(
                workspaceId: observedOwnerID,
                surfaceId: secondSurfaceID
            ),
            isUnread: true,
            totalUnreadCount: 2
        )
        #expect(recorder.values == [SidebarSurfaceUnreadProjection(
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
        let recorder = SidebarUnreadValueRecorder<SidebarUnreadSnapshot>()
        let observation = model.observeSummaryChanges(owner: recorder) { recorder, snapshot in
            recorder.values.append(snapshot)
        }
        defer { observation.cancel() }

        model.applySurfaceUnreadProjection(
            SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: surfaceID),
            isUnread: true,
            totalUnreadCount: 1
        )
        #expect(recorder.values.isEmpty)

        let summary = SidebarWorkspaceUnreadSummary(
            unreadCount: 1,
            latestNotificationText: nil
        )
        model.applyWorkspaceSummaryProjection(
            forWorkspaceId: workspaceID,
            summary: summary,
            totalUnreadCount: 1
        )
        #expect(recorder.values.map(\.summaryByWorkspaceId) == [[workspaceID: summary]])
    }

    @Test
    @MainActor
    func notificationIdentityChangesPublishWhenVisibleSummaryIsUnchanged() {
        let workspaceID = UUID()
        let firstNotificationID = UUID()
        let secondNotificationID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let model = SidebarUnreadModel()
        let recorder = SidebarUnreadValueRecorder<SidebarUnreadSnapshot>()
        let observation = model.observeSummaryChanges(owner: recorder) { recorder, snapshot in
            recorder.values.append(snapshot)
        }
        defer { observation.cancel() }

        model.applyWorkspaceSummaryProjection(
            forWorkspaceId: workspaceID,
            summary: SidebarWorkspaceUnreadSummary(
                unreadCount: 1,
                latestNotificationText: "Finished",
                latestNotificationId: firstNotificationID,
                latestNotificationCreatedAt: createdAt,
                hasLatestNotification: true
            ),
            totalUnreadCount: 1
        )
        model.applyWorkspaceSummaryProjection(
            forWorkspaceId: workspaceID,
            summary: SidebarWorkspaceUnreadSummary(
                unreadCount: 1,
                latestNotificationText: "Finished",
                latestNotificationId: secondNotificationID,
                latestNotificationCreatedAt: createdAt,
                hasLatestNotification: true
            ),
            totalUnreadCount: 1
        )

        #expect(recorder.values.count == 2)
        #expect(
            recorder.values.last?.summary(forWorkspaceId: workspaceID).latestNotificationId
                == secondNotificationID
        )
    }

    @Test
    @MainActor
    func reentrantPublicationsRemainOrderedForEveryObserver() {
        let model = SidebarUnreadModel()
        let first = SidebarUnreadValueRecorder<Int>()
        let second = SidebarUnreadValueRecorder<Int>()
        let receive: @MainActor (
            SidebarUnreadValueRecorder<Int>,
            SidebarUnreadSnapshot
        ) -> Void = { recorder, snapshot in
            recorder.values.append(snapshot.totalUnreadCount)
            guard !first.hasPublishedNestedValue else { return }
            first.hasPublishedNestedValue = true
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

        #expect(first.values == [1, 2])
        #expect(second.values == [1, 2])
        #expect(model.snapshot.totalUnreadCount == 2)
    }

    @Test
    @MainActor
    func reentrantSurfacePublicationsRemainOrderedForEveryObserver() {
        let ownerID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let model = SidebarUnreadModel()
        let first = SidebarUnreadValueRecorder<SidebarSurfaceUnreadProjection>()
        let second = SidebarUnreadValueRecorder<SidebarSurfaceUnreadProjection>()
        let receive: @MainActor (
            SidebarUnreadValueRecorder<SidebarSurfaceUnreadProjection>,
            SidebarSurfaceUnreadProjection
        ) -> Void = {
            recorder,
            projection in
            recorder.values.append(projection)
            guard !first.hasPublishedNestedValue else { return }
            first.hasPublishedNestedValue = true
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
        #expect(first.values == expected)
        #expect(second.values == expected)
    }
}
