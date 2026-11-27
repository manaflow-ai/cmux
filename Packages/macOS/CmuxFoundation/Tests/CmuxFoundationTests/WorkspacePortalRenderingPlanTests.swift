import Foundation
import Testing

import CmuxFoundation

@Suite("Workspace portal-rendering plan")
struct WorkspacePortalRenderingPlanTests {
    @Test("new unmounted workspaces are disabled once")
    func disablesNewUnmountedWorkspacesOnce() {
        let mounted = UUID()
        let unmounted = UUID()

        let initial = WorkspacePortalRenderingPlan(
            previousStatesByWorkspaceId: [:],
            mountedWorkspaceIds: [mounted],
            orderedWorkspaceIds: [mounted, unmounted]
        )

        #expect(
            initial.changes == [
                WorkspacePortalRenderingChange(workspaceId: mounted, isEnabled: true),
                WorkspacePortalRenderingChange(workspaceId: unmounted, isEnabled: false),
            ]
        )

        let repeated = WorkspacePortalRenderingPlan(
            previousStatesByWorkspaceId: initial.nextStatesByWorkspaceId,
            mountedWorkspaceIds: [mounted],
            orderedWorkspaceIds: [mounted, unmounted]
        )

        #expect(
            repeated.changes.isEmpty,
            "Already-disabled workspaces must not repeat portal hide work on every workspace switch"
        )
    }

    @Test("only mount transitions are reported")
    func reportsMountTransitionsOnly() {
        let previous = UUID()
        let selected = UUID()
        let stale = UUID()

        let plan = WorkspacePortalRenderingPlan(
            previousStatesByWorkspaceId: [
                previous: true,
                selected: false,
                stale: false,
            ],
            mountedWorkspaceIds: [selected],
            orderedWorkspaceIds: [previous, selected]
        )

        #expect(
            plan.changes == [
                WorkspacePortalRenderingChange(workspaceId: previous, isEnabled: false),
                WorkspacePortalRenderingChange(workspaceId: selected, isEnabled: true),
            ]
        )
        #expect(plan.nextStatesByWorkspaceId[previous] == false)
        #expect(plan.nextStatesByWorkspaceId[selected] == true)
        #expect(plan.nextStatesByWorkspaceId[stale] == nil)
    }

    @Test("applying advances the previous state snapshot")
    func applyingAdvancesPreviousStateSnapshot() {
        let mounted = UUID()
        let unmounted = UUID()
        var previousStates: [UUID: Bool] = [:]

        let changes = WorkspacePortalRenderingPlan(
            previousStatesByWorkspaceId: previousStates,
            mountedWorkspaceIds: [mounted],
            orderedWorkspaceIds: [mounted, unmounted]
        ).applying(to: &previousStates)

        #expect(
            changes == [
                WorkspacePortalRenderingChange(workspaceId: mounted, isEnabled: true),
                WorkspacePortalRenderingChange(workspaceId: unmounted, isEnabled: false),
            ]
        )
        #expect(previousStates[mounted] == true)
        #expect(previousStates[unmounted] == false)
    }

    @Test("duplicate ordered workspace ids are tolerated")
    func duplicateOrderedWorkspaceIdsAreTolerated() {
        let repeated = UUID()
        let mounted = UUID()

        let plan = WorkspacePortalRenderingPlan(
            previousStatesByWorkspaceId: [:],
            mountedWorkspaceIds: [mounted],
            orderedWorkspaceIds: [repeated, repeated, mounted]
        )

        #expect(
            plan.changes == [
                WorkspacePortalRenderingChange(workspaceId: repeated, isEnabled: false),
                WorkspacePortalRenderingChange(workspaceId: mounted, isEnabled: true),
            ]
        )
        #expect(plan.nextStatesByWorkspaceId[repeated] == false)
        #expect(plan.nextStatesByWorkspaceId[mounted] == true)
    }
}
