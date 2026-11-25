@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// A close's group cleanup and its Undo (`GroupCloseCleanup`): the cleanup's wait always ends and
/// deletes only a group that emptied; Undo never races the delete, and reopens only the record this
/// close's own delete made.
@MainActor @Suite struct GroupCloseCleanupTests {
    private static let group = WorkspaceGroupID(rawValue: "grp-close")

    /// The home store and closed history as the cleanup reads them. With `holds`, the delete
    /// suspends until the test lets it land, so a test can press Undo while it is in flight.
    @MainActor @Observable final class Home {
        var exists = true
        var pinned = false
        var memberLive = false
        var history: [(id: String, group: String?)] = []
        var deletes = 0
        var deleteSent = false
        var holds = false
        @ObservationIgnored var landing: CheckedContinuation<Void, Never>?

        func land() {
            exists = false
            history.insert(("rec-ours", GroupCloseCleanupTests.group.rawValue), at: 0)
            landing?.resume()
            landing = nil
        }

        func cleanup() -> GroupCloseCleanup {
            GroupCloseCleanup(GroupCloseCleanupTests.group, home: .init(
                exists: { self.exists },
                isEmptyUnpinned: { self.exists && !self.pinned && !self.memberLive },
                delete: {
                    self.deletes += 1
                    self.deleteSent = true
                    if self.holds { await withCheckedContinuation { self.landing = $0 } } else { self.land() }
                    return true
                },
                history: { self.history }))
        }
    }

    /// A close the daemon refuses leaves its member live: the wait ends at its deadline, not
    /// never, and the group stays.
    @Test func aRefusedCloseReturnsWithoutDeleting() async {
        let home = Home()
        home.memberLive = true
        let cleanup = home.cleanup(), start = ContinuousClock.now
        await cleanup.run(limit: .milliseconds(200))
        #expect(cleanup.state == .kept)
        #expect(home.deletes == 0, "a refused close deleted its group")
        #expect(ContinuousClock.now - start < .seconds(5), "the wait outlived its deadline")
    }

    /// The close event reaches the store after the wait began: the wait ends on it (not on the
    /// deadline) and the emptied group is deleted once.
    @Test func aCloseThatLandsDeletesTheEmptiedGroup() async {
        let home = Home()
        home.memberLive = true
        let cleanup = home.cleanup(), start = ContinuousClock.now
        // task-owner: this test; one store change
        Task { @MainActor in home.memberLive = false }
        await cleanup.run(limit: .seconds(30))
        #expect(cleanup.state == .deleted(before: []))
        #expect(home.deletes == 1)
        #expect(ContinuousClock.now - start < .seconds(10), "the wait ran to its deadline instead of ending on the close")
    }

    /// Something else deleted the group meanwhile (another window, the CLI): the cleanup ends at
    /// once and sends no second delete.
    @Test func aGroupAlreadyGoneIsNotDeletedAgain() async {
        let home = Home()
        home.exists = false
        let cleanup = home.cleanup()
        await cleanup.run(limit: .seconds(30))
        #expect(cleanup.state == .kept)
        #expect(home.deletes == 0)
    }

    /// Finding (a): Undo pressed while the delete is in flight waits for it, then names the record
    /// it made, so the group is reopened around the workspaces (before, Undo saw the group still
    /// present, skipped it, and the delete landed after, leaving the workspaces ungrouped).
    @Test func undoDuringAnInFlightDeleteWaitsAndRestoresTheGroup() async throws {
        let home = Home()
        home.holds = true
        home.history = [("rec-older", Self.group.rawValue)]
        let cleanup = home.cleanup()
        // task-owner: this test; ends when the delete lands
        let run = Task { @MainActor in await cleanup.run(limit: .seconds(5)) }
        await ObservationDeadline(owner: "group-close-cleanup-test").until({ home.deleteSent }, limit: .seconds(10))
        try #require(home.deleteSent)
        // task-owner: this test; ends with the undo
        let undo = Task { @MainActor in await cleanup.undo(limit: .seconds(5)) }
        await Task.yield()
        #expect(home.exists, "the delete landed before the test let it")
        home.land()
        await run.value
        #expect(await undo.value == "rec-ours")
        #expect(home.deletes == 1)
    }

    /// Finding (a): Undo pressed before the cleanup sent its delete stops it: no delete goes, the
    /// group stays for the reopened workspaces, and Undo has no record to reopen.
    @Test func undoBeforeTheDeleteIsSentCancelsIt() async {
        let home = Home()
        home.memberLive = true // the close has not landed yet
        let cleanup = home.cleanup()
        // task-owner: this test; ends on the cancel
        let run = Task { @MainActor in await cleanup.run(limit: .seconds(30)) }
        await Task.yield()
        #expect(await cleanup.undo(limit: .seconds(1)) == nil)
        home.memberLive = false
        await run.value
        #expect(home.deletes == 0, "the cleanup deleted the group after Undo stopped it")
        #expect(cleanup.state == .cancelled)
        #expect(home.exists)
    }

    /// Finding (b): a pinned group is never a group a close may delete.
    @Test func aPinnedGroupIsNotPrunable() {
        let pinned = WorkspaceGroupID(rawValue: "pinned"), loose = WorkspaceGroupID(rawValue: "loose")
        let rules = PersonalGroupLifecycle(groups: [.init(id: pinned, pinned: true), .init(id: loose, pinned: false)], rows: [])
        #expect(rules.prunable([pinned, loose]) == [loose])
    }

    /// Finding (b): a close that kept its group (pinned here) has no group Undo, even when a later,
    /// unrelated delete of the same group puts a fresh record in the history.
    @Test func aKeptGroupHasNoUndoEvenAfterALaterDelete() async {
        let home = Home()
        home.pinned = true
        let cleanup = home.cleanup()
        await cleanup.run(limit: .milliseconds(100))
        #expect(cleanup.state == .kept)
        home.history.insert(("rec-unrelated", Self.group.rawValue), at: 0)
        #expect(await cleanup.undo(limit: .milliseconds(100)) == nil)
        #expect(home.deletes == 0)
    }

    /// Finding (b): the record Undo reopens is the one this delete made, never an older one or a
    /// newer one from an unrelated delete of the same group.
    @Test func theRecordIsTheOneThisDeleteMade() {
        let history: [(id: String, group: String?)] = [("newer", "g"), ("other", "h"), ("ours", "g"), ("older", "g")]
        #expect(GroupCloseCleanup.record(of: "g", after: ["older"], newestFirst: history) == "ours")
        #expect(GroupCloseCleanup.record(of: "g", after: ["older", "ours", "newer"], newestFirst: history) == nil)
        #expect(GroupCloseCleanup.step(.kept) == .nothing)
        #expect(GroupCloseCleanup.step(.cancelled) == .nothing)
        #expect(GroupCloseCleanup.step(.waiting) == .cancel)
        #expect(GroupCloseCleanup.step(.deleting(before: [])) == .wait)
    }
}
