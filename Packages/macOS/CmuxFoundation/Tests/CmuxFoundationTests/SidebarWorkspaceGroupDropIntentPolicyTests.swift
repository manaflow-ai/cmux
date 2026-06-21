import Testing

@testable import CmuxFoundation

@Suite struct SidebarWorkspaceGroupDropIntentPolicyTests {
    @Test func pointerInsideGroupIndentPrefersGroupScope() {
        #expect(SidebarWorkspaceGroupDropIntentPolicy.prefersGroupScope(pointerX: 0, memberIndent: 12))
        #expect(SidebarWorkspaceGroupDropIntentPolicy.prefersGroupScope(pointerX: -6, memberIndent: 12))
    }

    @Test func pointerPastRootSideOfIndentDoesNotPreferGroupScope() {
        #expect(!SidebarWorkspaceGroupDropIntentPolicy.prefersGroupScope(pointerX: -7, memberIndent: 12))
    }
}
