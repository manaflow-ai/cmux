import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class WorkstreamStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var workstreamId: UUID?
    var isPinned: Bool
    var currentDirectory: String

    init(
        id: UUID = UUID(),
        groupId: UUID? = nil,
        workstreamId: UUID? = nil,
        isPinned: Bool = false,
        currentDirectory: String = "/tmp"
    ) {
        self.id = id
        self.groupId = groupId
        self.workstreamId = workstreamId
        self.isPinned = isPinned
        self.currentDirectory = currentDirectory
    }
}

@MainActor
struct WorkstreamCoordinatorTests {
    private func makeWorld(tabCount: Int = 0) -> (
        model: WorkspacesModel<WorkstreamStubTab>,
        coordinator: WorkstreamCoordinator<WorkstreamStubTab>,
        tabs: [WorkstreamStubTab]
    ) {
        let model = WorkspacesModel<WorkstreamStubTab>()
        let tabs = (0..<tabCount).map { _ in WorkstreamStubTab() }
        model.tabs = tabs
        let coordinator = WorkstreamCoordinator(model: model)
        return (model, coordinator, tabs)
    }

    // MARK: - Creation

    @Test
    func createAssignsNameAndMembers() {
        let world = makeWorld(tabCount: 3)
        let id = world.coordinator.createWorkstream(
            name: "Checkout revamp",
            memberWorkspaceIds: [world.tabs[0].id, world.tabs[2].id]
        )
        #expect(world.model.workstreams.count == 1)
        #expect(world.model.workstream(id: id)?.name == "Checkout revamp")
        #expect(world.tabs[0].workstreamId == id)
        #expect(world.tabs[1].workstreamId == nil)
        #expect(world.tabs[2].workstreamId == id)
        #expect(world.model.memberCount(ofWorkstream: id) == 2)
    }

    @Test
    func createWithBlankNameUsesAutoName() {
        let world = makeWorld()
        let id = world.coordinator.createWorkstream(name: "   ")
        #expect(world.model.workstream(id: id)?.name == "Workstream 1")
    }

    @Test
    func autoNameSkipsCollisions() {
        let world = makeWorld()
        _ = world.coordinator.createWorkstream(name: "Workstream 1")
        let second = world.coordinator.createWorkstream(name: "")
        // "Workstream 1" is taken; count+1 == 2 is free.
        #expect(world.model.workstream(id: second)?.name == "Workstream 2")
    }

    @Test
    func createReassignsMembershipExclusively() {
        let world = makeWorld(tabCount: 1)
        let a = world.coordinator.createWorkstream(name: "A", memberWorkspaceIds: [world.tabs[0].id])
        let b = world.coordinator.createWorkstream(name: "B", memberWorkspaceIds: [world.tabs[0].id])
        #expect(world.tabs[0].workstreamId == b)
        #expect(world.model.memberCount(ofWorkstream: a) == 0)
        #expect(world.model.memberCount(ofWorkstream: b) == 1)
    }

    // MARK: - Rename

    @Test
    func renameTrimsAndIgnoresBlank() {
        let world = makeWorld()
        let id = world.coordinator.createWorkstream(name: "Old")
        world.coordinator.renameWorkstream(id: id, name: "  New name  ")
        #expect(world.model.workstream(id: id)?.name == "New name")
        world.coordinator.renameWorkstream(id: id, name: "   ")
        #expect(world.model.workstream(id: id)?.name == "New name")
    }

    // MARK: - Deletion

    @Test
    func deleteReleasesMembersWithoutClosingThem() {
        let world = makeWorld(tabCount: 2)
        let id = world.coordinator.createWorkstream(
            name: "WS",
            memberWorkspaceIds: [world.tabs[0].id, world.tabs[1].id]
        )
        let released = world.coordinator.deleteWorkstream(id: id)
        #expect(released == 2)
        #expect(world.model.workstreams.isEmpty)
        // Workspaces survive, just unassigned.
        #expect(world.model.tabs.count == 2)
        #expect(world.tabs[0].workstreamId == nil)
        #expect(world.tabs[1].workstreamId == nil)
    }

    @Test
    func deletingDrilledInWorkstreamExitsDrillIn() {
        let world = makeWorld(tabCount: 1)
        let id = world.coordinator.createWorkstream(name: "WS", memberWorkspaceIds: [world.tabs[0].id])
        world.coordinator.enterWorkstream(id: id)
        #expect(world.model.drilledInWorkstreamId == id)
        world.coordinator.deleteWorkstream(id: id)
        #expect(world.model.drilledInWorkstreamId == nil)
    }

    // MARK: - Membership add/remove

    @Test
    func addAndRemoveWorkspace() {
        let world = makeWorld(tabCount: 1)
        let id = world.coordinator.createWorkstream(name: "WS")
        world.coordinator.addWorkspaceToWorkstream(workspaceId: world.tabs[0].id, workstreamId: id)
        #expect(world.tabs[0].workstreamId == id)
        world.coordinator.removeWorkspaceFromWorkstream(workspaceId: world.tabs[0].id)
        #expect(world.tabs[0].workstreamId == nil)
    }

    @Test
    func addToUnknownWorkstreamIsNoOp() {
        let world = makeWorld(tabCount: 1)
        world.coordinator.addWorkspaceToWorkstream(workspaceId: world.tabs[0].id, workstreamId: UUID())
        #expect(world.tabs[0].workstreamId == nil)
    }

    // MARK: - Ordering

    @Test
    func moveWorkstreamReorders() {
        let world = makeWorld()
        let a = world.coordinator.createWorkstream(name: "A")
        let b = world.coordinator.createWorkstream(name: "B")
        let c = world.coordinator.createWorkstream(name: "C")
        world.coordinator.moveWorkstream(id: c, toIndex: 0)
        #expect(world.model.workstreams.map(\.id) == [c, a, b])
        // Clamps out-of-range targets.
        world.coordinator.moveWorkstream(id: c, toIndex: 99)
        #expect(world.model.workstreams.map(\.id) == [a, b, c])
    }

    @Test
    func relativeMoveTargetIndexCompensatesForSourceRemoval() {
        typealias C = WorkstreamCoordinator<WorkstreamStubTab>
        // "A after B" in [A,B,C]: source idx 0, peer idx 1 -> final idx 1.
        #expect(C.relativeMoveTargetIndex(currentIndex: 0, peerIndex: 1, after: true) == 1)
        // "A before C": source 0, peer 2 -> 1.
        #expect(C.relativeMoveTargetIndex(currentIndex: 0, peerIndex: 2, after: false) == 1)
        // "C before A": source 2, peer 0 -> 0.
        #expect(C.relativeMoveTargetIndex(currentIndex: 2, peerIndex: 0, after: false) == 0)
        // "C after A": source 2, peer 0 -> 1.
        #expect(C.relativeMoveTargetIndex(currentIndex: 2, peerIndex: 0, after: true) == 1)
        #expect(C.relativeMoveTargetIndex(currentIndex: 1, peerIndex: 1, after: false) == 1)
        #expect(C.relativeMoveTargetIndex(currentIndex: 1, peerIndex: 1, after: true) == 1)
    }

    @Test
    func relativeMoveProducesExpectedOrderDownward() {
        // The regression from review: "move A after B" must yield [B,A,C].
        let world = makeWorld()
        let a = world.coordinator.createWorkstream(name: "A")
        let b = world.coordinator.createWorkstream(name: "B")
        let c = world.coordinator.createWorkstream(name: "C")
        let target = WorkstreamCoordinator<WorkstreamStubTab>.relativeMoveTargetIndex(
            currentIndex: 0, peerIndex: 1, after: true
        )
        world.coordinator.moveWorkstream(id: a, toIndex: target)
        #expect(world.model.workstreams.map(\.id) == [b, a, c])
    }

    @Test
    func relativeMoveAgainstSelfKeepsOrder() {
        let world = makeWorld()
        let a = world.coordinator.createWorkstream(name: "A")
        let b = world.coordinator.createWorkstream(name: "B")
        let c = world.coordinator.createWorkstream(name: "C")
        let target = WorkstreamCoordinator<WorkstreamStubTab>.relativeMoveTargetIndex(
            currentIndex: 1, peerIndex: 1, after: true
        )
        world.coordinator.moveWorkstream(id: b, toIndex: target)
        #expect(world.model.workstreams.map(\.id) == [a, b, c])
    }

    @Test
    func membershipChangesBumpRevision() {
        let world = makeWorld(tabCount: 1)
        let id = world.coordinator.createWorkstream(name: "WS")
        let before = world.model.workstreamMembershipRevision
        world.coordinator.addWorkspaceToWorkstream(workspaceId: world.tabs[0].id, workstreamId: id)
        #expect(world.model.workstreamMembershipRevision > before)
        let afterAdd = world.model.workstreamMembershipRevision
        world.coordinator.removeWorkspaceFromWorkstream(workspaceId: world.tabs[0].id)
        #expect(world.model.workstreamMembershipRevision > afterAdd)
    }

    // MARK: - Drill-in navigation

    @Test
    func enterAndExitDrillIn() {
        let world = makeWorld()
        let id = world.coordinator.createWorkstream(name: "WS")
        world.coordinator.enterWorkstream(id: id)
        #expect(world.model.drilledInWorkstreamId == id)
        world.coordinator.exitWorkstreamDrillIn()
        #expect(world.model.drilledInWorkstreamId == nil)
    }

    @Test
    func enterUnknownWorkstreamIsNoOp() {
        let world = makeWorld()
        world.coordinator.enterWorkstream(id: UUID())
        #expect(world.model.drilledInWorkstreamId == nil)
    }

    @Test
    func enterDoesNotChangeSelection() {
        let world = makeWorld(tabCount: 2)
        world.model.selectedTabId = world.tabs[1].id
        let id = world.coordinator.createWorkstream(name: "WS", memberWorkspaceIds: [world.tabs[0].id])
        world.coordinator.enterWorkstream(id: id)
        // Drilling in is a view concern only; focus is untouched.
        #expect(world.model.selectedTabId == world.tabs[1].id)
    }

    // MARK: - Drill-in visibility filter

    @Test
    func visibilityIsIdentityWithNoWorkstreams() {
        // Zero-regression contract: with no workstreams and no drill-in, every
        // workspace is visible at the top level.
        let world = makeWorld(tabCount: 4)
        let visible = world.model.tabsVisibleInSidebar().map(\.id)
        #expect(visible == world.tabs.map(\.id))
    }

    @Test
    func visibilityFiltersByDrillInState() {
        let world = makeWorld(tabCount: 4)
        let id = world.coordinator.createWorkstream(
            name: "WS",
            memberWorkspaceIds: [world.tabs[1].id, world.tabs[3].id]
        )
        // Top level: only workstream-less workspaces.
        #expect(world.model.tabsVisibleInSidebar().map(\.id) == [world.tabs[0].id, world.tabs[2].id])
        // Drilled in: only that workstream's workspaces, in tab order.
        world.coordinator.enterWorkstream(id: id)
        #expect(world.model.tabsVisibleInSidebar().map(\.id) == [world.tabs[1].id, world.tabs[3].id])
    }

    // MARK: - Invariants

    @Test
    func normalizeClearsDanglingReferences() {
        let world = makeWorld(tabCount: 2)
        let ghost = UUID()
        world.tabs[0].workstreamId = ghost
        world.model.drilledInWorkstreamId = ghost
        world.model.normalizeWorkstreamState()
        #expect(world.tabs[0].workstreamId == nil)
        #expect(world.model.drilledInWorkstreamId == nil)
    }

    @Test
    func normalizeKeepsValidReferences() {
        let world = makeWorld(tabCount: 1)
        let id = world.coordinator.createWorkstream(name: "WS", memberWorkspaceIds: [world.tabs[0].id])
        world.coordinator.enterWorkstream(id: id)
        world.model.normalizeWorkstreamState()
        #expect(world.tabs[0].workstreamId == id)
        #expect(world.model.drilledInWorkstreamId == id)
    }
}
