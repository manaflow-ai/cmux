import CmuxMobileShellModel
import Testing

@testable import CmuxMobileWorkspace

@Suite struct WorkspaceShellCompactNavigationPolicyTests {
    @Test func doesNotAutoPushWhenAttachSelectsWorkspace() {
        let path = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-a")
        )

        #expect(path.isEmpty)
    }

    @Test func pushesNewlyCreatedWorkspaceFromList() {
        let path = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-created"),
            existingWorkspaceIDs: [
                .init(rawValue: "workspace-a"),
                .init(rawValue: "workspace-b"),
            ]
        )

        #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-created")])
    }

    @Test func doesNotTreatExistingSelectionAsCreatedWorkspace() {
        let path = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-a"),
            existingWorkspaceIDs: [
                .init(rawValue: "workspace-a"),
                .init(rawValue: "workspace-b"),
            ]
        )

        #expect(path == nil)
    }

    @Test func ignoresCreatedWorkspaceSelectionWhenNoCreateIsPending() {
        let path = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-created"),
            existingWorkspaceIDs: nil
        )

        #expect(path == nil)
    }

    @Test func tracksSelectionAfterUserOpenedWorkspace() {
        let path = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            selectedWorkspaceID: MobileWorkspacePreview.ID(rawValue: "workspace-b")
        )

        #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-b")])
    }

    @Test func clearsWhenSelectedWorkspaceDisappears() {
        let path = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            selectedWorkspaceID: nil,
            visibleWorkspaceIDs: [MobileWorkspacePreview.ID(rawValue: "workspace-b")]
        )

        #expect(path.isEmpty)
    }

    @Test func keepsVisibleDetailRouteWhenSelectionClearsTransiently() {
        let selectedID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let path = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
            currentPath: [selectedID],
            selectedWorkspaceID: nil,
            visibleWorkspaceIDs: [selectedID, MobileWorkspacePreview.ID(rawValue: "workspace-b")]
        )

        #expect(path == [selectedID])
    }

    @Test func keepsSelectedDetailRouteWhenVisibleWorkspaceIDsTemporarilyOmitIt() {
        let selectedID = MobileWorkspacePreview.ID(rawValue: "workspace-created")
        let path = WorkspaceShellCompactNavigationPolicy.pathForVisibleWorkspaceIDsChange(
            currentPath: [selectedID],
            visibleWorkspaceIDs: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            selectedWorkspaceID: selectedID
        )

        #expect(path == [selectedID])
    }

    @Test func removesMissingDetailRouteWhenItIsNoLongerSelected() {
        let selectedID = MobileWorkspacePreview.ID(rawValue: "workspace-b")
        let path = WorkspaceShellCompactNavigationPolicy.pathForVisibleWorkspaceIDsChange(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            visibleWorkspaceIDs: [selectedID],
            selectedWorkspaceID: selectedID
        )

        #expect(path.isEmpty)
    }
}
