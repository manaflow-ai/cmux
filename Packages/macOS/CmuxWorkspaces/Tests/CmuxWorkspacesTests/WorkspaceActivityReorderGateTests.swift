import CmuxSettings
import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("WorkspaceActivityReorderGate")
struct WorkspaceActivityReorderGateTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let idle = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: false, isSidebarInteracting: false)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: Modes

    @Test func offNeverMoves() {
        var gate = WorkspaceActivityReorderGate()
        let id = UUID()
        #expect(gate.admit(workspaceId: id, trigger: .notification, mode: .off, context: idle, now: start) == .ignore)
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .off, context: idle, now: start) == .ignore)
        #expect(gate.pendingWorkspaceIds.isEmpty)
    }

    @Test func notificationsModeKeepsLegacyBehavior() {
        var gate = WorkspaceActivityReorderGate()
        let id = UUID()
        // Agent transitions never move in the legacy mode.
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .notifications, context: idle, now: start) == .ignore)
        // Notifications move every time, with no throttle and no hover gate.
        let hovering = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: false, isSidebarInteracting: true)
        #expect(gate.admit(workspaceId: id, trigger: .notification, mode: .notifications, context: idle, now: start) == .moveNow)
        #expect(gate.admit(workspaceId: id, trigger: .notification, mode: .notifications, context: hovering, now: at(1)) == .moveNow)
    }

    @Test func agentActivityMovesOnBothTriggers() {
        var gate = WorkspaceActivityReorderGate()
        #expect(gate.admit(workspaceId: UUID(), trigger: .agentActivity, mode: .agentActivity, context: idle, now: start) == .moveNow)
        #expect(gate.admit(workspaceId: UUID(), trigger: .notification, mode: .agentActivity, context: idle, now: start) == .moveNow)
    }

    // MARK: Pinned and selected

    @Test func pinnedWorkspacesStayPut() {
        var gate = WorkspaceActivityReorderGate()
        let id = UUID()
        let pinned = WorkspaceActivityReorderGate.Context(isPinned: true, isSelected: false, isSidebarInteracting: false)
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: pinned, now: start) == .ignore)
        #expect(gate.pendingWorkspaceIds.isEmpty)
    }

    @Test func selectedWorkspaceNeverMoves() {
        var gate = WorkspaceActivityReorderGate()
        let id = UUID()
        let selected = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: true, isSidebarInteracting: false)
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: selected, now: start) == .ignore)
        #expect(gate.pendingWorkspaceIds.isEmpty)
    }

    @Test func pendingMoveIsDroppedWhenTheWorkspaceBecomesSelectedOrPinned() {
        var gate = WorkspaceActivityReorderGate()
        let selectedLater = UUID()
        let pinnedLater = UUID()
        let hovering = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: false, isSidebarInteracting: true)
        #expect(gate.admit(workspaceId: selectedLater, trigger: .agentActivity, mode: .agentActivity, context: hovering, now: start) == .deferred)
        #expect(gate.admit(workspaceId: pinnedLater, trigger: .agentActivity, mode: .agentActivity, context: hovering, now: start) == .deferred)

        let moved = gate.drain(mode: .agentActivity, now: at(1)) { id in
            id == selectedLater
                ? .init(isPinned: false, isSelected: true, isSidebarInteracting: false)
                : .init(isPinned: true, isSelected: false, isSidebarInteracting: false)
        }
        #expect(moved.isEmpty)
        #expect(gate.pendingWorkspaceIds.isEmpty)
    }

    @Test func workspaceAlreadyOnTopIsLeftAloneAndItsPendingMoveDropped() {
        var gate = WorkspaceActivityReorderGate(cooldown: 10)
        let id = UUID()
        let onTop = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: false, isAtTop: true, isSidebarInteracting: false)
        // The journal event moved the row; its notification arrives next.
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: idle, now: start) == .moveNow)
        #expect(gate.admit(workspaceId: id, trigger: .notification, mode: .agentActivity, context: onTop, now: at(0.1)) == .ignore)
        #expect(gate.pendingWorkspaceIds.isEmpty)

        // A request deferred while displaced is dropped if the row is back on top.
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: idle, now: at(1)) == .deferred)
        #expect(gate.drain(mode: .agentActivity, now: at(10)) { _ in onTop }.isEmpty)
        #expect(gate.pendingWorkspaceIds.isEmpty)
    }

    // MARK: Hover and drag

    @Test func hoverOrDragDefersInsteadOfMoving() {
        var gate = WorkspaceActivityReorderGate()
        let id = UUID()
        let hovering = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: false, isSidebarInteracting: true)
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: hovering, now: start) == .deferred)
        #expect(gate.pendingWorkspaceIds == [id])

        // Still hovering: nothing is released.
        #expect(gate.drain(mode: .agentActivity, now: at(2)) { _ in hovering }.isEmpty)
        #expect(gate.pendingWorkspaceIds == [id])
        // A deferral that waits on interaction has no cooldown deadline.
        #expect(gate.nextCooldownEnd(after: at(2)) == nil)

        // Pointer left the sidebar: the move is released once.
        #expect(gate.drain(mode: .agentActivity, now: at(3)) { _ in idle } == [id])
        #expect(gate.pendingWorkspaceIds.isEmpty)
        #expect(gate.drain(mode: .agentActivity, now: at(4)) { _ in idle }.isEmpty)
    }

    // MARK: Debounce

    @Test func aBurstMovesAtMostOncePerCooldown() {
        var gate = WorkspaceActivityReorderGate(cooldown: 10)
        let id = UUID()
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: idle, now: start) == .moveNow)
        // Finish, new prompt, finish again inside the window: one pending move.
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: idle, now: at(1)) == .deferred)
        #expect(gate.admit(workspaceId: id, trigger: .notification, mode: .agentActivity, context: idle, now: at(2)) == .ignore)
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: idle, now: at(3)) == .deferred)
        #expect(gate.pendingWorkspaceIds == [id])
        #expect(gate.nextCooldownEnd(after: at(3)) == at(10))

        #expect(gate.drain(mode: .agentActivity, now: at(9)) { _ in idle }.isEmpty)
        #expect(gate.drain(mode: .agentActivity, now: at(10)) { _ in idle } == [id])
        // The trailing move restarts the cooldown.
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: idle, now: at(15)) == .deferred)
        #expect(gate.admit(workspaceId: id, trigger: .agentActivity, mode: .agentActivity, context: idle, now: at(21)) == .moveNow)
    }

    @Test func aNotificationInsideTheCooldownDoesNotLiftTheRowLater() {
        var gate = WorkspaceActivityReorderGate(cooldown: 10)
        let a = UUID()
        let b = UUID()
        // A's journal event moves A, then B's moves B above it.
        #expect(gate.admit(workspaceId: a, trigger: .agentActivity, mode: .agentActivity, context: idle, now: start) == .moveNow)
        #expect(gate.admit(workspaceId: b, trigger: .agentActivity, mode: .agentActivity, context: idle, now: at(1)) == .moveNow)
        // A's notification for the same event arrives with A no longer on top.
        #expect(gate.admit(workspaceId: a, trigger: .notification, mode: .agentActivity, context: idle, now: at(2)) == .ignore)
        #expect(gate.pendingWorkspaceIds.isEmpty)
        #expect(gate.drain(mode: .agentActivity, now: at(20)) { _ in idle }.isEmpty)
    }

    @Test func cooldownIsPerWorkspace() {
        var gate = WorkspaceActivityReorderGate(cooldown: 10)
        #expect(gate.admit(workspaceId: UUID(), trigger: .agentActivity, mode: .agentActivity, context: idle, now: start) == .moveNow)
        #expect(gate.admit(workspaceId: UUID(), trigger: .agentActivity, mode: .agentActivity, context: idle, now: at(1)) == .moveNow)
    }

    @Test func drainReleasesOldestFirstSoNewestEndsOnTop() {
        var gate = WorkspaceActivityReorderGate()
        let first = UUID()
        let second = UUID()
        let hovering = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: false, isSidebarInteracting: true)
        _ = gate.admit(workspaceId: second, trigger: .agentActivity, mode: .agentActivity, context: hovering, now: at(2))
        _ = gate.admit(workspaceId: first, trigger: .agentActivity, mode: .agentActivity, context: hovering, now: at(1))
        #expect(gate.drain(mode: .agentActivity, now: at(3)) { _ in idle } == [first, second])
    }

    @Test func drainDropsRequestsForClosedWorkspacesAndWhenTheModeChanges() {
        var gate = WorkspaceActivityReorderGate()
        let hovering = WorkspaceActivityReorderGate.Context(isPinned: false, isSelected: false, isSidebarInteracting: true)
        _ = gate.admit(workspaceId: UUID(), trigger: .agentActivity, mode: .agentActivity, context: hovering, now: start)
        #expect(gate.drain(mode: .agentActivity, now: at(1)) { _ in nil }.isEmpty)
        #expect(gate.pendingWorkspaceIds.isEmpty)

        _ = gate.admit(workspaceId: UUID(), trigger: .agentActivity, mode: .agentActivity, context: hovering, now: start)
        #expect(gate.drain(mode: .notifications, now: at(1)) { _ in idle }.isEmpty)
        #expect(gate.pendingWorkspaceIds.isEmpty)
    }
}
