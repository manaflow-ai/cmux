import CmuxSurfaceCatalogModel
import Testing
@testable import CmuxCloud

@Suite("Cloud terminal attachment placement policy")
struct CloudTerminalAttachmentPlacementPolicyTests {
    private let resource = SurfaceResourceID(
        machine: .cloud("placement-policy-machine"), kind: .terminal, key: "term_live"
    )

    @Test
    func restoredRepairAcceptsOnlyAReplacementInTheSavedWorkspace() throws {
        let policy = CloudTerminalAttachmentPlacementPolicy(
            expectedResource: resource,
            expectedWorkspaceID: "saved-workspace",
            expectedTabID: "deleted-tab",
            allowsRepair: true
        )
        let replacement = SurfaceRemotePlacement(workspaceID: "saved-workspace", tabID: "repaired-tab")
        #expect(try policy.validate(
            resourceID: resource, remoteTabID: "deleted-tab",
            catalogPlacement: nil, materializedPlacement: nil
        ) == nil)
        #expect(try policy.validate(
            resourceID: resource, remoteTabID: "deleted-tab",
            catalogPlacement: nil, materializedPlacement: replacement
        ) == replacement)
        #expect(throws: CloudDiagnosticFailure.placement) {
            try policy.validate(
                resourceID: resource, remoteTabID: "deleted-tab", catalogPlacement: nil,
                materializedPlacement: SurfaceRemotePlacement(workspaceID: "other-workspace", tabID: "repaired-tab")
            )
        }
    }

    @Test(arguments: [false, true])
    func missingPlacementPolicyRespectsRepairFlag(allowsRepair: Bool) throws {
        let policy = CloudTerminalAttachmentPlacementPolicy(
            expectedResource: resource,
            expectedWorkspaceID: "saved-workspace",
            expectedTabID: "saved-tab",
            allowsRepair: allowsRepair
        )
        if allowsRepair {
            #expect(try policy.validate(
                resourceID: resource, remoteTabID: "saved-tab",
                catalogPlacement: nil,
                materializedPlacement: SurfaceRemotePlacement(workspaceID: "saved-workspace", tabID: "replacement")
            ) != nil)
        } else {
            #expect(throws: CloudDiagnosticFailure.placement) {
                try policy.validate(
                    resourceID: resource, remoteTabID: "saved-tab",
                    catalogPlacement: nil,
                    materializedPlacement: SurfaceRemotePlacement(workspaceID: "saved-workspace", tabID: "replacement")
                )
            }
        }
    }

    @Test
    func resourceAndTabIdentityRemainStrictDuringRepair() {
        let policy = CloudTerminalAttachmentPlacementPolicy(
            expectedResource: resource,
            expectedWorkspaceID: "saved-workspace",
            expectedTabID: "saved-tab",
            allowsRepair: true
        )
        #expect(throws: CloudDiagnosticFailure.placement) {
            try policy.validate(
                resourceID: SurfaceResourceID(machine: resource.machine, kind: .terminal, key: "other"),
                remoteTabID: "saved-tab", catalogPlacement: nil,
                materializedPlacement: SurfaceRemotePlacement(workspaceID: "saved-workspace", tabID: "replacement")
            )
        }
        #expect(throws: CloudDiagnosticFailure.placement) {
            try policy.validate(
                resourceID: resource, remoteTabID: "other-tab", catalogPlacement: nil,
                materializedPlacement: SurfaceRemotePlacement(workspaceID: "saved-workspace", tabID: "replacement")
            )
        }
    }
}
