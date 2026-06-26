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
            isCycleHot: false,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspaces
        ).mountedWorkspaceIds

        #expect(next == [selected])
    }
}
