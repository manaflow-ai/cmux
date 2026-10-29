import AppKit
import CmuxNextFocusUI
import Foundation
import Testing

/// The creations a window's held keys wait for (``CreationInputBuffer``): the target each creation's keys are stamped
/// with in the window's ``WindowInputQueue``, and what closes, fails or follows it. It holds no key and no timer
/// (principled audit, lagFirstKey: the 2 s bound and its forced flush are gone).
@MainActor @Suite struct CreationInputHoldTests {
    private static func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// A creation with a provisional tab stamps its keys with that tab; one without (a split on a daemon that makes the
    /// pane only at its reply) with a stand-in id of its own, never another creation's.
    @Test func eachCreationHasItsOwnTarget() throws {
        let buffer = CreationInputBuffer()
        let first = buffer.open(generation: 1, tab: "first")
        let second = buffer.open(generation: 2)
        let third = buffer.open(generation: 3)
        let targets = try [first, second, third].map { try #require(buffer.creation($0)).target }
        #expect(targets[0] == WindowInputQueue.Target("first"))
        #expect(Set(targets).count == 3, "two creations share a target: \(targets)")
        #expect(buffer.newest?.generation == 3)
    }

    /// Lawrence 2026-10-23: Cmd-D, type, Cmd-D, type, Cmd-W. The Cmd-W closes the second new pane before the daemon made
    /// it: only that creation is cancelled, so only the keys typed for it drop; the first pane's keep waiting for it.
    @Test func closingAPendingCreationCancelsOnlyThatCreation() throws {
        let buffer = CreationInputBuffer()
        let queue = WindowInputQueue(dropped: { _, _, _ in })
        let first = try #require(buffer.creation(buffer.open(generation: 1, tab: "first"))).target
        let forFirst = Self.key("a", code: 0)
        queue.capture(forFirst, for: first)
        let second = try #require(buffer.creation(buffer.open(generation: 2, tab: "second"))).target
        queue.capture(Self.key("b", code: 11), for: second)

        let cancelled = buffer.cancel(tab: "second")
        #expect(cancelled.map(\.target) == [second])
        for creation in cancelled { queue.drop(creation.target, .targetClosed) }
        var sent: [NSEvent] = []
        queue.drain(first, takesKeys: { true }) { sent.append($0) }
        #expect(sent == [forFirst], "the keys typed for the closed pane went to another one")
        #expect(queue.isEmpty)
        #expect(queue.problems.isEmpty, "\(queue.problems)")
    }

    /// Only a creation still waiting for its reply is cancelled by a close of its tab: one that replied is the daemon's.
    @Test func aCreationIsCancelledOnlyWhileItIsPending() {
        let buffer = CreationInputBuffer()
        let ticket = buffer.open(generation: 1, tab: "new")
        #expect(buffer.isCreating(tab: "new"))
        buffer.resolve(ticket, landed: true)
        #expect(!buffer.isCreating(tab: "new"))
        #expect(buffer.cancel(tab: "new").isEmpty)
        #expect(buffer.creation(ticket)?.landed == true, "a replied creation's keys wait for its focus")
    }

    /// A failed creation is removed and handed back (the coordinator drops its keys, reason targetFailed); so is a new
    /// workspace whose reply named no workspace. A made workspace is kept with its id.
    @Test func aFailedCreationIsRemovedAndHandedBack() throws {
        let buffer = CreationInputBuffer()
        let failed = buffer.open(generation: 1, tab: "gone")
        #expect(buffer.resolve(failed, landed: false)?.landed == false)
        #expect(buffer.creation(failed) == nil)

        let noWorkspace = buffer.open(generation: 2, newWorkspace: true)
        #expect(buffer.resolve(noWorkspace, landed: true, workspace: nil)?.landed == false, "a new workspace that was not made counted as made")
        #expect(buffer.creation(noWorkspace) == nil)

        let made = buffer.open(generation: 3, newWorkspace: true)
        buffer.resolve(made, landed: true, workspace: "ws-new")
        let creation = try #require(buffer.creation(made))
        #expect(creation.landed && creation.workspace == "ws-new" && creation.awaitsTab)
        #expect(buffer.hasPendingCreation == false)
    }

    /// A Ctrl-` stand-in its daemon tab adopted: the creation follows the new tab id, so its keys go to that view and a
    /// close of it still cancels it (review of a8acc611977, finding B).
    @Test func aCreationFollowsTheStandInToItsDaemonTab() {
        let buffer = CreationInputBuffer()
        _ = buffer.open(generation: 1, earlyTab: "standin", tab: "standin")
        let moved = buffer.rekey(tab: "standin", to: "daemon")
        #expect(moved.map { $0.1 } == [WindowInputQueue.Target("daemon")])
        #expect(buffer.newestEarlyTab == "daemon")
        #expect(buffer.isCreating(tab: "daemon"))
        #expect(!buffer.isCreating(tab: "standin"))
        #expect(buffer.cancel(tab: "daemon").count == 1, "a close of the adopted stand-in did not cancel its creation")
    }
}
