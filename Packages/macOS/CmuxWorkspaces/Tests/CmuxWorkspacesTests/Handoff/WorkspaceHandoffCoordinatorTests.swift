import Foundation
import Testing
@testable import CmuxWorkspaces

/// In-memory window host for ``WorkspaceHandoffCoordinator``: an ordered
/// workspace list plus per-workspace readiness and pinning inputs, and records
/// of the portal-render mutations, unfocus completions, and DEBUG events the
/// coordinator drives.
@MainActor
private final class FakeWorkspaceHandoffHost: WorkspaceHandoffHosting {
    var ordered: [UUID] = []
    var selectedWorkspaceId: UUID?
    var mountedBackgroundWorkspaceLoadIds: Set<UUID> = []
    var debugPinnedWorkspaceLoadIds: Set<UUID> = []
    var isWorkspaceCycleHot = false
    /// Workspaces ready for immediate handoff; ids absent here are "not ready"
    /// (the fallback timer arms). A gone workspace (not in `ordered`) is ready,
    /// matching the legacy `tabs.first(where:) == nil` short-circuit.
    var readyWorkspaceIds: Set<UUID> = []

    var portalToggles: [(workspaceId: UUID, enabled: Bool, reason: String)] = []
    var unfocusReasons: [String] = []
    var events: [WorkspaceHandoffEvent] = []

    func orderedWorkspaceIds() -> [UUID] { ordered }

    func setWorkspacePortalRenderingEnabled(workspaceId: UUID, enabled: Bool, reason: String) {
        portalToggles.append((workspaceId, enabled, reason))
    }

    func workspaceIsReadyForImmediateHandoff(workspaceId: UUID) -> Bool {
        guard ordered.contains(workspaceId) else { return true }
        return readyWorkspaceIds.contains(workspaceId)
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        unfocusReasons.append(reason)
    }

    func logWorkspaceHandoffEvent(_ event: WorkspaceHandoffEvent) {
        events.append(event)
    }

    /// The most recent enabled state the coordinator set for a workspace.
    func lastPortalState(_ workspaceId: UUID) -> Bool? {
        portalToggles.last(where: { $0.workspaceId == workspaceId })?.enabled
    }
}

/// A clock whose `sleep(for:)` never resumes until the test cancels the task,
/// so the fallback-timeout path can be observed as "armed but not fired"
/// without real wall-clock waiting. Cancellation throws, matching
/// `ContinuousClock` behavior the coordinator's `do/catch` relies on.
private struct NeverClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // Suspend until the surrounding task is cancelled.
        try await Task.sleep(nanoseconds: .max)
    }
}

@MainActor
@Suite struct WorkspaceHandoffCoordinatorTests {
    private func makeCoordinator(
        host: FakeWorkspaceHandoffHost
    ) -> WorkspaceHandoffCoordinator {
        let coordinator = WorkspaceHandoffCoordinator(clock: NeverClock())
        coordinator.attach(host: host)
        return coordinator
    }

    @Test func reconcileMountsSelectedAndTogglesPortals() {
        let a = UUID(), b = UUID()
        let host = FakeWorkspaceHandoffHost()
        host.ordered = [a, b]
        host.selectedWorkspaceId = a
        let coordinator = makeCoordinator(host: host)

        coordinator.reconcileMountedWorkspaceIds()

        #expect(coordinator.mountedWorkspaceIds == [a])
        // Every workspace gets a portal toggle; only the selected one is enabled.
        #expect(host.lastPortalState(a) == true)
        #expect(host.lastPortalState(b) == false)
    }

    @Test func startHandoffWithoutPriorSelectionClearsState() {
        let a = UUID()
        let host = FakeWorkspaceHandoffHost()
        host.ordered = [a]
        host.selectedWorkspaceId = a
        let coordinator = makeCoordinator(host: host)

        // No previous selection seeded → no handoff, completes pending unfocus
        // with "no_handoff" and leaves no retiring workspace.
        coordinator.startWorkspaceHandoffIfNeeded(newSelectedId: a)

        #expect(coordinator.retiringWorkspaceId == nil)
        #expect(host.unfocusReasons == ["no_handoff"])
    }

    @Test func realSelectionChangeToReadyWorkspaceCompletesImmediately() {
        let a = UUID(), b = UUID()
        let host = FakeWorkspaceHandoffHost()
        host.ordered = [a, b]
        host.selectedWorkspaceId = a
        host.readyWorkspaceIds = [b]
        let coordinator = makeCoordinator(host: host)
        coordinator.seedPreviousSelection() // previous = a

        host.selectedWorkspaceId = b
        coordinator.startWorkspaceHandoffIfNeeded(newSelectedId: b)

        // Fast-ready path: retiring cleared, unfocus completed with "ready",
        // retiring workspace's portal disabled.
        #expect(coordinator.retiringWorkspaceId == nil)
        #expect(host.unfocusReasons == ["ready"])
        #expect(host.lastPortalState(a) == false)
    }

    @Test func realSelectionChangeToUnreadyWorkspaceRetiresAndArmsFallback() {
        let a = UUID(), b = UUID()
        let host = FakeWorkspaceHandoffHost()
        host.ordered = [a, b]
        host.selectedWorkspaceId = a
        host.readyWorkspaceIds = [] // b not ready → fallback arms (NeverClock keeps it pending)
        let coordinator = makeCoordinator(host: host)
        coordinator.seedPreviousSelection()

        host.selectedWorkspaceId = b
        coordinator.startWorkspaceHandoffIfNeeded(newSelectedId: b)

        // Handoff in flight: a is retiring, no completion yet.
        #expect(coordinator.retiringWorkspaceId == a)
        #expect(host.unfocusReasons.isEmpty)
    }

    @Test func completeIfNeededFiresOnlyForSelectedWithHandoffInFlight() {
        let a = UUID(), b = UUID()
        let host = FakeWorkspaceHandoffHost()
        host.ordered = [a, b]
        host.selectedWorkspaceId = a
        host.readyWorkspaceIds = []
        let coordinator = makeCoordinator(host: host)
        coordinator.seedPreviousSelection()
        host.selectedWorkspaceId = b
        coordinator.startWorkspaceHandoffIfNeeded(newSelectedId: b)
        #expect(coordinator.retiringWorkspaceId == a)

        // Focus event for a non-selected workspace is ignored.
        coordinator.completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: a, reason: "focus")
        #expect(coordinator.retiringWorkspaceId == a)

        // Focus event for the selected workspace completes the handoff.
        coordinator.completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: b, reason: "focus")
        #expect(coordinator.retiringWorkspaceId == nil)
        #expect(host.unfocusReasons == ["focus"])
    }

    @Test func pruneRemovedRetiringWorkspaceClearsRetiringState() {
        let a = UUID(), b = UUID()
        let host = FakeWorkspaceHandoffHost()
        host.ordered = [a, b]
        host.selectedWorkspaceId = a
        host.readyWorkspaceIds = []
        let coordinator = makeCoordinator(host: host)
        coordinator.seedPreviousSelection()
        host.selectedWorkspaceId = b
        coordinator.startWorkspaceHandoffIfNeeded(newSelectedId: b)
        #expect(coordinator.retiringWorkspaceId == a)

        // a (the retiring workspace) is removed → retiring state drops.
        host.ordered = [b]
        coordinator.pruneRemovedWorkspaces(existingWorkspaceIds: [b])
        #expect(coordinator.retiringWorkspaceId == nil)
    }

    @Test func retiringWorkspaceStaysPinnedMountedDuringHandoff() {
        let a = UUID(), b = UUID()
        let host = FakeWorkspaceHandoffHost()
        host.ordered = [a, b]
        host.selectedWorkspaceId = a
        host.readyWorkspaceIds = []
        let coordinator = makeCoordinator(host: host)
        coordinator.reconcileMountedWorkspaceIds()
        coordinator.seedPreviousSelection()

        host.selectedWorkspaceId = b
        coordinator.startWorkspaceHandoffIfNeeded(newSelectedId: b)
        coordinator.reconcileMountedWorkspaceIds(selectedId: b)

        // During handoff the retiring workspace (a) is pinned, so both the new
        // selection and the retiring one stay mounted.
        #expect(Set(coordinator.mountedWorkspaceIds) == [a, b])
    }
}
