import Testing

@testable import CmuxFoundation

@Suite struct SidebarWorkspaceDragActivationPolicyTests {
    private let policy = SidebarWorkspaceDragActivationPolicy()

    @Test func localGroupAnchorCanRecoverFromTheActiveNativeSession() {
        #expect(!policy.shouldRejectRecovery(
            isLocalWorkspace: true,
            isSourceGroupAnchor: true
        ))
    }

    @Test func foreignGroupAnchorRemainsRejected() {
        #expect(policy.shouldRejectRecovery(
            isLocalWorkspace: false,
            isSourceGroupAnchor: true
        ))
    }

    @Test(arguments: [true, false])
    func regularWorkspaceRecoveryRemainsAllowed(isLocalWorkspace: Bool) {
        #expect(!policy.shouldRejectRecovery(
            isLocalWorkspace: isLocalWorkspace,
            isSourceGroupAnchor: false
        ))
    }
}
