import Testing
@testable import CmuxWindowing

@Suite("DetachedSourceWorkspaceCleanupPolicy")
struct DetachedSourceWorkspaceCleanupPolicyTests {
    private let policy = DetachedSourceWorkspaceCleanupPolicy()

    @Test("leaves a non-empty source workspace untouched")
    func nonEmptyIsNone() {
        #expect(
            policy.outcome(
                sourceWorkspaceIsEmpty: false,
                sourceWorkspaceStillInManager: true,
                sourceManagerWorkspaceCount: 3
            ) == .none
        )
    }

    @Test("leaves an empty workspace alone when it is no longer in the manager")
    func goneFromManagerIsNone() {
        #expect(
            policy.outcome(
                sourceWorkspaceIsEmpty: true,
                sourceWorkspaceStillInManager: false,
                sourceManagerWorkspaceCount: 1
            ) == .none
        )
    }

    @Test("closes just the workspace when the window holds other workspaces")
    func emptyWithSiblingsClosesWorkspace() {
        #expect(
            policy.outcome(
                sourceWorkspaceIsEmpty: true,
                sourceWorkspaceStillInManager: true,
                sourceManagerWorkspaceCount: 2
            ) == .closeWorkspace
        )
    }

    @Test("closes the window when the empty workspace is the only one")
    func emptyOnlyWorkspaceClosesWindow() {
        #expect(
            policy.outcome(
                sourceWorkspaceIsEmpty: true,
                sourceWorkspaceStillInManager: true,
                sourceManagerWorkspaceCount: 1
            ) == .closeWindow
        )
    }

    @Test("a non-empty count is irrelevant when the workspace is not empty")
    func nonEmptyWithSingleCountIsStillNone() {
        #expect(
            policy.outcome(
                sourceWorkspaceIsEmpty: false,
                sourceWorkspaceStillInManager: true,
                sourceManagerWorkspaceCount: 1
            ) == .none
        )
    }
}
