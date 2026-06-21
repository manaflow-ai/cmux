import Testing

@testable import CmuxFoundation

@Suite struct SidebarWorkspaceGroupDropIntentPolicyTests {
    @Test func pointerInsideGroupIndentPrefersGroupScope() {
        let policy = SidebarWorkspaceGroupDropIntentPolicy(memberIndent: 12)

        #expect(policy.prefersGroupScope(pointerX: 6, targetLeadingIndent: 12))
        #expect(policy.prefersGroupScope(pointerX: 12, targetLeadingIndent: 12))
    }

    @Test func pointerPastRootSideOfIndentDoesNotPreferGroupScope() {
        let policy = SidebarWorkspaceGroupDropIntentPolicy(memberIndent: 12)

        #expect(!policy.prefersGroupScope(pointerX: 5, targetLeadingIndent: 12))
        #expect(!policy.prefersGroupScope(pointerX: 20, targetLeadingIndent: 0))
    }
}
