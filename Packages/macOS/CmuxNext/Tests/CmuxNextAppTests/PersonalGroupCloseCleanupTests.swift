@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Observation
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

/// The bounded wait of a close's group cleanup (`PersonalGroupLife.deleteWhenEmpty`): it always
/// returns, by the close landing or by its deadline, and deletes only a group that emptied.
@MainActor @Suite struct PersonalGroupCloseSettleTests {
    /// The home store as the cleanup reads it: whether the group's last member is still live,
    /// whether the group still exists, and the deletes the cleanup sent.
    @MainActor @Observable final class Home {
        var memberLive = true
        var groupExists = true
        var deletes = 0
    }

    private static func settle(_ home: Home, limit: Duration) async -> PersonalGroupLife.CloseCleanup {
        await PersonalGroupLife.settle(
            limit: limit,
            settled: { !home.groupExists || !home.memberLive },
            deletable: { home.groupExists && !home.memberLive },
            delete: { home.deletes += 1 })
    }

    /// A close the daemon refuses leaves its member live: the wait ends at its deadline, not
    /// never, and the group stays.
    @Test func aRefusedCloseReturnsWithoutDeleting() async {
        let home = Home()
        let start = ContinuousClock.now
        let outcome = await Self.settle(home, limit: .milliseconds(200))
        #expect(outcome == .kept)
        #expect(home.deletes == 0, "a refused close deleted its group")
        #expect(ContinuousClock.now - start < .seconds(5), "the wait outlived its deadline")
    }

    /// The close event reaches the store after the wait began: the wait ends on it (not on the
    /// deadline) and the emptied group is deleted once.
    @Test func aCloseThatLandsDeletesTheEmptiedGroup() async {
        let home = Home()
        let start = ContinuousClock.now
        // task-owner: this test; one store change
        Task { @MainActor in home.memberLive = false }
        let outcome = await Self.settle(home, limit: .seconds(30))
        #expect(outcome == .deleted)
        #expect(home.deletes == 1)
        #expect(ContinuousClock.now - start < .seconds(10), "the wait ran to its deadline instead of ending on the close")
    }

    /// A close's Undo reopens the workspaces first, then the record of each group the cleanup may
    /// have deleted, so each group forms again around its reopened workspaces.
    @Test func theUndoReopensTheWorkspacesBeforeTheGroupsTheyEmptied() {
        let groups = WorkspaceGroupClose.undoGroups(["a", "b"], pruned: [WorkspaceGroupID(rawValue: "g2"), WorkspaceGroupID(rawValue: "g1")])
        #expect(groups.map(\.0) == [nil, "g1", "g2"])
        #expect(groups.map(\.1) == [["a", "b"], [], []])
    }

    /// Something else deleted the group meanwhile (another window, the CLI): the cleanup ends at
    /// once and sends no second delete.
    @Test func aGroupAlreadyGoneIsNotDeletedAgain() async {
        let home = Home()
        home.groupExists = false
        let outcome = await Self.settle(home, limit: .seconds(30))
        #expect(outcome == .kept)
        #expect(home.deletes == 0)
    }
}
