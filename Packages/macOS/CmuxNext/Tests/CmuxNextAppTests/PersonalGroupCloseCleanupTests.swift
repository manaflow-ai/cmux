@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

@Suite struct PersonalGroupCloseCleanupTests {
    private static let group = WorkspaceGroupID(rawValue: "grp-agent")

    private static func row(_ key: String, group: WorkspaceGroupID? = nil) -> PersonalWorkspace {
        PersonalWorkspace(sessionID: "session", workspaceKey: WorkspaceKey(rawValue: key), index: 0, group: group ?? Self.group)
    }

    @Test func anUnpinnedGroupIsDeletableAfterItsLastLiveWorkspaceCloses() {
        let rows = [Self.row("closed")]
        let closed = Set(["closed"])
        #expect(PersonalGroupLifecycle.shouldDeleteAfterClose(
            .init(id: Self.group, pinned: false), rows: rows,
            isLive: { !closed.contains($0.key) }))
    }

    @Test func aPinnedGroupSurvivesWhenItsLastWorkspaceCloses() {
        let rows = [Self.row("closed")]
        #expect(!PersonalGroupLifecycle.shouldDeleteAfterClose(
            .init(id: Self.group, pinned: true), rows: rows,
            isLive: { _ in false }))
    }

    @Test func aGroupWithAnotherLiveWorkspaceStays() {
        let rows = [Self.row("closed"), Self.row("live")]
        #expect(!PersonalGroupLifecycle.shouldDeleteAfterClose(
            .init(id: Self.group, pinned: false), rows: rows,
            isLive: { $0.key == "live" }))
    }
}
