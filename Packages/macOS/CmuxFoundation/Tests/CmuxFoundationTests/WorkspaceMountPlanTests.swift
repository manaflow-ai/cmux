import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct WorkspaceMountPlanTests {
    @Test func keepsSelectedWorkspaceMountedWhenOrderTemporarilyOmitsIt() {
        let selected = UUID()
        let other = UUID()

        let next = WorkspaceMountPlan(
            current: [selected],
            selected: selected,
            pinnedIds: [],
            orderedTabIds: [other],
            activeWorkspaceIds: [selected, other],
            isCycleHot: false,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspaces
        ).mountedWorkspaceIds

        #expect(next == [selected])
    }

    @Test func dropsSelectedWorkspaceWhenActiveSourceDoesNotConfirmIt() {
        let selected = UUID()
        let other = UUID()

        let next = WorkspaceMountPlan(
            current: [selected, other],
            selected: selected,
            pinnedIds: [],
            orderedTabIds: [other],
            activeWorkspaceIds: [other],
            isCycleHot: false,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspaces
        ).mountedWorkspaceIds

        #expect(next == [other])
    }

    @Test func cycleHotDoesNotWarmSelectedWorkspaceWhenActiveSourceDoesNotConfirmIt() {
        let selected = UUID()
        let other = UUID()

        let next = WorkspaceMountPlan(
            current: [selected, other],
            selected: selected,
            pinnedIds: [],
            orderedTabIds: [other],
            activeWorkspaceIds: [other],
            isCycleHot: true,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspacesDuringCycle
        ).mountedWorkspaceIds

        #expect(next == [other])
    }

    @Test func pinnedWorkspaceKeepsPriorityWhenSelectedWorkspaceIsNotActive() {
        let selected = UUID()
        let other = UUID()
        let pinned = UUID()

        let next = WorkspaceMountPlan(
            current: [other],
            selected: selected,
            pinnedIds: [pinned],
            orderedTabIds: [other, pinned],
            activeWorkspaceIds: [other, pinned],
            isCycleHot: false,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspaces
        ).mountedWorkspaceIds

        #expect(next == [pinned])
    }
}
