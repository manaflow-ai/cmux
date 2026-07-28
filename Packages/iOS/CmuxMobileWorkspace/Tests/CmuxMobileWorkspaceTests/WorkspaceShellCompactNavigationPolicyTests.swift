import CmuxMobileShellModel
import Testing

@testable import CmuxMobileWorkspace

@Suite struct WorkspaceShellCompactNavigationPolicyTests {
    private let policy = WorkspaceShellCompactNavigationPolicy()

    @Test func doesNotAutoPushWhenAttachSelectsWorkspace() {
        let path = policy.pathForSelectionChange(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-a")
        )

        #expect(path.isEmpty)
    }

    @Test func pushesNewlyCreatedWorkspaceFromList() {
        let path = policy.pathForCreatedWorkspaceSelection(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-created"),
            existingWorkspaceIDs: [
                .init(rawValue: "workspace-a"),
                .init(rawValue: "workspace-b"),
            ]
        )

        #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-created")])
    }

    @Test func composerSuccessFromEmptyPathPushesCreatedWorkspace() {
        let path = policy.pathForCompletedCreate(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-created"),
            existingWorkspaceIDs: [.init(rawValue: "workspace-a")],
            succeeded: true
        )

        #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-created")])
    }

    @Test func composerFailureClearsPendingIntentWithoutPushing() {
        let path = policy.pathForCompletedCreate(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-created"),
            existingWorkspaceIDs: [.init(rawValue: "workspace-a")],
            succeeded: false
        )

        #expect(path == nil)
    }

    @Test func composerSuccessRetargetsExistingNonemptyPath() {
        let path = policy.pathForCompletedCreate(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-open")],
            selectedWorkspaceID: MobileWorkspacePreview.ID(rawValue: "workspace-created"),
            existingWorkspaceIDs: [
                MobileWorkspacePreview.ID(rawValue: "workspace-a"),
                MobileWorkspacePreview.ID(rawValue: "workspace-open"),
            ],
            succeeded: true
        )

        #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-created")])
    }

    @Test func doesNotTreatExistingSelectionAsCreatedWorkspace() {
        let path = policy.pathForCreatedWorkspaceSelection(
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
        let path = policy.pathForCreatedWorkspaceSelection(
            currentPath: [MobileWorkspacePreview.ID](),
            selectedWorkspaceID: .init(rawValue: "workspace-created"),
            existingWorkspaceIDs: nil
        )

        #expect(path == nil)
    }

    @Test func tracksSelectionAfterUserOpenedWorkspace() {
        let path = policy.pathForSelectionChange(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            selectedWorkspaceID: MobileWorkspacePreview.ID(rawValue: "workspace-b")
        )

        #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-b")])
    }

    @Test func clearsWhenSelectionClears() {
        let path = policy.pathForSelectionChange(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            selectedWorkspaceID: nil,
            visibleWorkspaceIDs: [MobileWorkspacePreview.ID(rawValue: "workspace-b")]
        )

        #expect(path.isEmpty)
    }

    @Test func clearsVisibleDetailRouteWhenSelectionClears() {
        let selectedID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let path = policy.pathForSelectionChange(
            currentPath: [selectedID],
            selectedWorkspaceID: nil,
            visibleWorkspaceIDs: [selectedID, MobileWorkspacePreview.ID(rawValue: "workspace-b")]
        )

        #expect(path.isEmpty)
    }

    @Test func keepsSelectedDetailRouteWhenVisibleWorkspaceIDsTemporarilyOmitIt() {
        let selectedID = MobileWorkspacePreview.ID(rawValue: "workspace-created")
        let path = policy.pathForVisibleWorkspaceIDsChange(
            currentPath: [selectedID],
            visibleWorkspaceIDs: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            selectedWorkspaceID: selectedID
        )

        #expect(path == [selectedID])
    }

    @Test func remapsDetailRouteWhenListRefreshOmitsItAfterSelectionRetargets() {
        let selectedID = MobileWorkspacePreview.ID(rawValue: "workspace-b")
        let path = policy.pathForVisibleWorkspaceIDsChange(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            visibleWorkspaceIDs: [selectedID],
            selectedWorkspaceID: selectedID
        )

        #expect(path == [selectedID])
    }

    @Test func removesMissingDetailRouteWhenSelectionClears() {
        let path = policy.pathForVisibleWorkspaceIDsChange(
            currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
            visibleWorkspaceIDs: [MobileWorkspacePreview.ID(rawValue: "workspace-b")],
            selectedWorkspaceID: nil
        )

        #expect(path.isEmpty)
    }
}
