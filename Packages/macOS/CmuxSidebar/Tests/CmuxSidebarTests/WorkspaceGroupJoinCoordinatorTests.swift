import Foundation
import Testing
import CmuxSettings
@testable import CmuxSidebar

/// In-memory fake of the ``WorkspaceGroupJoining`` seam. Records joins and lets
/// a test drive the observed workspace list, so the coordinator's registry
/// lifecycle is asserted without the app-target `TabManager`.
@MainActor
private final class FakeJoinHost: WorkspaceGroupJoining {
    var workspaceIds: [UUID]
    var liveGroupIds: Set<UUID>
    private(set) var joins: [(workspace: UUID, group: UUID, placement: WorkspaceGroupNewPlacement, reference: UUID?)] = []
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    init(workspaceIds: [UUID] = [], liveGroupIds: Set<UUID> = []) {
        self.workspaceIds = workspaceIds
        self.liveGroupIds = liveGroupIds
    }

    func currentWorkspaceIds() -> [UUID] { workspaceIds }
    func groupContainsLiveGroup(_ groupId: UUID) -> Bool { liveGroupIds.contains(groupId) }
    func containsWorkspace(_ workspaceId: UUID) -> Bool { workspaceIds.contains(workspaceId) }

    func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    ) {
        joins.append((workspaceId, groupId, placement, referenceWorkspaceId))
    }

    func observeWorkspaceList(
        _ onChange: @escaping @MainActor () -> Void
    ) -> any WorkspaceGroupJoinObservation {
        let token = FakeObservation { [weak self] handle in
            self?.observers.removeValue(forKey: ObjectIdentifier(handle))
        }
        observers[ObjectIdentifier(token)] = onChange
        return token
    }

    /// Mutates the list and fires every live observer, mimicking an `@Observable`
    /// list change.
    func setWorkspaceIds(_ ids: [UUID]) {
        workspaceIds = ids
        for fire in observers.values { fire() }
    }

    var activeObserverCount: Int { observers.count }

    @MainActor
    private final class FakeObservation: WorkspaceGroupJoinObservation {
        private var onCancel: ((FakeObservation) -> Void)?
        init(onCancel: @escaping (FakeObservation) -> Void) { self.onCancel = onCancel }
        func cancel() {
            onCancel?(self)
            onCancel = nil
        }
    }
}

@MainActor
@Suite struct WorkspaceGroupJoinCoordinatorTests {
    @Test func installJoinsNextUnknownWorkspaceThenDisposes() {
        let group = UUID()
        let host = FakeJoinHost(liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        // No workspaces yet, so nothing joined and the watch is still armed.
        #expect(host.joins.isEmpty)
        #expect(host.activeObserverCount == 1)

        let created = UUID()
        host.setWorkspaceIds([created])

        #expect(host.joins.count == 1)
        #expect(host.joins.first?.workspace == created)
        #expect(host.joins.first?.group == group)
        // Self-cleared after the join: the observer is cancelled.
        #expect(host.activeObserverCount == 0)
    }

    @Test func installScansExistingWorkspacesImmediately() {
        let group = UUID()
        let preexisting = UUID()
        let host = FakeJoinHost(workspaceIds: [preexisting], liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        // A workspace already present at install time joins on the immediate
        // scan (the bridge's replay-on-subscribe behavior).
        #expect(host.joins.count == 1)
        #expect(host.joins.first?.workspace == preexisting)
        #expect(host.activeObserverCount == 0)
    }

    @Test func knownWorkspacesAreNotJoined() {
        let group = UUID()
        let known = UUID()
        let host = FakeJoinHost(workspaceIds: [known], liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        coordinator.install(
            host: host,
            groupId: group,
            knownIds: [known],
            placement: .end,
            referenceWorkspaceId: nil
        )
        #expect(host.joins.isEmpty)
        // Watch stays armed for a genuinely new workspace.
        #expect(host.activeObserverCount == 1)
    }

    @Test func disappearedGroupAbortsWatchWithoutJoining() {
        let group = UUID()
        let host = FakeJoinHost(liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        host.liveGroupIds = []
        host.setWorkspaceIds([UUID()])

        #expect(host.joins.isEmpty)
        #expect(host.activeObserverCount == 0)
    }

    @Test func finishPendingJoinsNamedWorkspace() {
        let group = UUID()
        let host = FakeJoinHost(liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        let observerId = coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        let created = UUID()
        host.workspaceIds = [created]
        coordinator.finishPending(host: host, observerId: observerId, workspaceId: created)

        #expect(host.joins.count == 1)
        #expect(host.joins.first?.workspace == created)
        #expect(host.activeObserverCount == 0)
    }

    @Test func finishPendingWithFailureDisposesWithoutJoining() {
        let group = UUID()
        let host = FakeJoinHost(liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        let observerId = coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        coordinator.finishPending(host: host, observerId: observerId, workspaceId: nil)

        #expect(host.joins.isEmpty)
        #expect(host.activeObserverCount == 0)
    }

    @Test func installReplacesPriorWatchForSameHost() {
        let group = UUID()
        let host = FakeJoinHost(liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        let firstId = coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        // A second install for the same host disposes the first watch.
        let secondId = coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        #expect(firstId != secondId)
        #expect(host.activeObserverCount == 1)

        // finishPending against the stale id is a no-op.
        coordinator.finishPending(host: host, observerId: firstId, workspaceId: UUID())
        #expect(host.joins.isEmpty)
    }

    @Test func disposePendingCancelsMatchingWatch() {
        let group = UUID()
        let host = FakeJoinHost(liveGroupIds: [group])
        let coordinator = WorkspaceGroupJoinCoordinator()

        let observerId = coordinator.install(
            host: host,
            groupId: group,
            knownIds: [],
            placement: .end,
            referenceWorkspaceId: nil
        )
        coordinator.disposePending(host: host, observerId: observerId)
        #expect(host.activeObserverCount == 0)

        // Further list changes do not join after disposal.
        host.setWorkspaceIds([UUID()])
        #expect(host.joins.isEmpty)
    }
}
