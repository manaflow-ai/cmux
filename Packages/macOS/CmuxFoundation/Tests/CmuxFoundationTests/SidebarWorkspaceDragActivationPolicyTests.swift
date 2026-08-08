import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarWorkspaceDragActivationPolicyTests {
    private let policy = SidebarWorkspaceDragActivationPolicy()

    @Test func localGroupAnchorCanMirrorTheActiveNativeSession() {
        #expect(!policy.shouldRejectMirroring(
            isLocalWorkspace: true,
            isSourceGroupAnchor: true
        ))
    }

    @Test func foreignGroupAnchorRemainsRejected() {
        #expect(policy.shouldRejectMirroring(
            isLocalWorkspace: false,
            isSourceGroupAnchor: true
        ))
    }

    @Test(arguments: [true, false])
    func regularWorkspaceMirroringRemainsAllowed(isLocalWorkspace: Bool) {
        #expect(!policy.shouldRejectMirroring(
            isLocalWorkspace: isLocalWorkspace,
            isSourceGroupAnchor: false
        ))
    }

    @Test func liveLocalSessionRestoresDismissedPresentationIdentity() {
        let workspaceId = UUID()

        #expect(policy.resolvedLocalWorkspaceId(
            liveSessionWorkspaceId: workspaceId,
            isLocalWorkspace: true
        ) == workspaceId)
    }

    @Test(arguments: [true, false])
    func missingOrForeignSessionCannotDriveLocalPresentation(isLocalWorkspace: Bool) {
        #expect(policy.resolvedLocalWorkspaceId(
            liveSessionWorkspaceId: nil,
            isLocalWorkspace: isLocalWorkspace
        ) == nil)

        let foreignWorkspaceId = UUID()
        #expect(policy.resolvedLocalWorkspaceId(
            liveSessionWorkspaceId: foreignWorkspaceId,
            isLocalWorkspace: false
        ) == nil)
    }
}
