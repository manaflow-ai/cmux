import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct WorkspaceMountPlanTests {
    @Test func keepsSelectedWorkspaceMountedWhenPublisherTemporarilyOmitsIt() {
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
}
