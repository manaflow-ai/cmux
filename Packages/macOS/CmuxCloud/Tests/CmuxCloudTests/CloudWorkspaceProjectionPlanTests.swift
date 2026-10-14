@testable import CmuxCloud
import Foundation
import CmuxSurfaceCatalogModel
import Testing

@MainActor
@Suite("Cloud workspace projection reconciliation")
struct CloudWorkspaceProjectionPlanTests {
    private let machine = SurfaceMachineID.cloud("desktop-plan")

    @Test("A workspace display shown by its own pane is listed once")
    func membershipDisplayIsNotListedTwiceForItsLocalPane() {
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let workspace = SurfaceRemoteWorkspace(id: "remote-workspace", name: "layout", index: 0, focused: true)
        let pool = SurfaceResource(id: display, title: "Display 1", detail: nil, lifecycle: .running,
                                   agent: nil, remoteWorkspace: nil, remoteViews: nil, port: 6901, url: nil)
        // `cloudWorkspaceResources` appends a copy of a member display that
        // carries the membership view, keeping the pool resource first.
        var member = pool
        member.remoteViews = [SurfaceRemoteView(
            tabID: SurfaceRemoteView.cloudDisplayMembershipViewPrefix + "view-1",
            workspace: workspace, name: nil, index: 0, focused: false
        )]
        member.remoteWorkspace = workspace
        let pane = SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                     remoteWorkspaceID: workspace.id)

        let extra = SurfaceProjection.localWorkspaceMembers(resources: [pool, member], projections: [pane])

        #expect(extra.isEmpty)
    }

    @Test("A local Desktop preview survives a refresh with a remote placement")
    func localDisplayPreviewIsNotClosedAsObsolete() {
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let preview = SurfaceProjection(
            resource: display,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "remote-workspace"
        )
        let desired = SurfaceResourcePlacement(
            resource: display,
            remoteWorkspaceID: "remote-workspace",
            remoteTabID: "remote-tab"
        )

        let plan = CloudWorkspaceProjectionPlan(desired: [desired], existing: [preview])

        #expect(plan.obsolete.isEmpty)
        #expect(plan.missing == [desired])
    }

    @Test("A local Desktop preview satisfies an exact frontend membership view")
    func localDisplayPreviewSatisfiesMembership() {
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let preview = SurfaceProjection(
            resource: display,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "remote-workspace"
        )
        let remoteWorkspace = SurfaceRemoteWorkspace(
            id: "remote-workspace", name: "Cloud", index: 0, focused: true
        )
        let desired = SurfaceResourcePlacement(
            resource: display,
            remoteView: SurfaceRemoteView(
                tabID: SurfaceRemoteView.cloudDisplayMembershipViewPrefix + "view-a",
                workspace: remoteWorkspace
            )
        )
        let secondView = SurfaceResourcePlacement(
            resource: display,
            remoteView: SurfaceRemoteView(
                tabID: SurfaceRemoteView.cloudDisplayMembershipViewPrefix + "view-b",
                workspace: remoteWorkspace
            )
        )

        let plan = CloudWorkspaceProjectionPlan(desired: [desired, secondView], existing: [preview])

        #expect(plan.obsolete.isEmpty)
        #expect(plan.missing.isEmpty)
    }

    @Test("A local Desktop preview satisfies its own workspace row, with or without a membership view")
    func localDisplayPreviewSatisfiesItsWorkspaceRow() {
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let preview = SurfaceProjection(
            resource: display,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "remote-workspace"
        )
        let workspaceRow = SurfaceResourcePlacement(resource: display, remoteWorkspaceID: "remote-workspace")
        let membership = SurfaceResourcePlacement(
            resource: display,
            remoteView: SurfaceRemoteView(
                tabID: SurfaceRemoteView.cloudDisplayMembershipViewPrefix + "view-a",
                workspace: SurfaceRemoteWorkspace(id: "remote-workspace", name: "Cloud", index: 0, focused: true)
            )
        )

        // The workspace group lists each local preview as a row of its own. A
        // preview reported missing is reprojected on every reconcile.
        for desired in [[workspaceRow], [workspaceRow, membership]] {
            let plan = CloudWorkspaceProjectionPlan(desired: desired, existing: [preview])
            #expect(plan.obsolete.isEmpty)
            #expect(plan.missing.isEmpty)
        }
    }

    @Test("A preview whose remote placement was deleted is retired")
    func deletedRemotePlacementIsNotMistakenForPreview() {
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let deleted = SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID())
        let plan = CloudWorkspaceProjectionPlan(desired: [], existing: [deleted])

        #expect(plan.obsolete == [deleted])
        #expect(plan.missing.isEmpty)
    }

    @Test("A stale remote terminal remains eligible for reconciliation")
    func staleRemotePlacementIsObsolete() {
        let terminal = SurfaceResourceID(machine: machine, kind: .terminal, key: "terminal-1")
        let existing = SurfaceProjection(
            resource: terminal,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "old-workspace",
            remoteTabID: "old-tab"
        )
        let desired = SurfaceResourcePlacement(
            resource: terminal,
            remoteWorkspaceID: "new-workspace",
            remoteTabID: "new-tab"
        )

        let plan = CloudWorkspaceProjectionPlan(desired: [desired], existing: [existing])

        #expect(plan.obsolete == [existing])
        #expect(plan.missing == [desired])
    }

    @Test("A terminal tab the workspace already shows is neither missing nor obsolete")
    func projectedTerminalPlacementIsSatisfied() {
        let terminal = SurfaceResourceID(machine: machine, kind: .terminal, key: "terminal-1")
        let existing = SurfaceProjection(
            resource: terminal,
            workspaceID: UUID(),
            panelID: UUID(),
            remoteWorkspaceID: "workspace",
            remoteTabID: "tab"
        )
        let desired = SurfaceResourcePlacement(
            resource: terminal,
            remoteWorkspaceID: "workspace",
            remoteTabID: "tab"
        )

        let plan = CloudWorkspaceProjectionPlan(desired: [desired], existing: [existing])

        // A shown tab reported as missing is reprojected on every reconcile, and
        // each reprojection requests the next reconcile of the same machine.
        #expect(plan.obsolete.isEmpty)
        #expect(plan.missing.isEmpty)
    }
}
