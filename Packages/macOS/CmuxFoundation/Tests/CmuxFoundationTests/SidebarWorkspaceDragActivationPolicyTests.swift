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
}
