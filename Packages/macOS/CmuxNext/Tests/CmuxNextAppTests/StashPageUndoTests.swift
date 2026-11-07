import CmuxNextDesign
@testable import CmuxNextHistoryPages
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Stashed Tabs page's delete (`cmux.stash.delete`, ``StashPageProvider``): one click is one
/// delete, and the stash goes only when the Undo toast's time runs out. Undo, a newer toast in its
/// place, the page's close and the call's cancel keep it.
@MainActor @Suite(.serialized)
struct StashPageUndoTests {
    /// The Undo toasts the provider showed, each with how to end it and whether it was taken down.
    @MainActor final class Toasts {
        final class Shown {
            let toast: CmuxToast
            let end: @MainActor (CmuxToastDismissReason) -> Void
            var dismissed = false
            init(_ toast: CmuxToast, _ end: @escaping @MainActor (CmuxToastDismissReason) -> Void) {
                self.toast = toast
                self.end = end
            }
        }

        var shown: [Shown] = []

        func present(_ toast: CmuxToast, _ ended: @escaping @MainActor (CmuxToastDismissReason) -> Void) -> (() -> Void)? {
            let item = Shown(toast, ended)
            shown.append(item)
            return { item.dismissed = true }
        }
    }

    /// The daemon's side: lists stash `s1` with members `m1` and `m2`.
    final class Relay: PageProvider {
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            guard op == "cmux.stash.list" else { return .object([:]) }
            return [["id": "s1", "members": [["id": "m1"], ["id": "m2"]]]]
        }
    }

    struct World {
        let provider: StashPageProvider
        let toasts: Toasts
        let deleted: Box
    }

    @MainActor final class Box {
        var calls: [String] = []
        var restored: [(String, [String]?)] = []
        var deletedMembers: [[String]?] = []
    }

    static func world() -> World {
        let toasts = Toasts()
        let deleted = Box()
        let provider = StashPageProvider(restore: { id, members, _ in deleted.restored.append((id, members)) },
                                         delete: { id, members in
                                             deleted.calls.append(id)
                                             deleted.deletedMembers.append(members)
                                         },
                                         importEngine: { "webkit" }, relay: Relay())
        provider.presentUndo = { toast, ended in toasts.present(toast, ended) }
        return World(provider: provider, toasts: toasts, deleted: deleted)
    }

    static func click(_ at: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.stash", userGesture: true, gestureEvent: at)
    }

    static func delete(_ world: World, _ stash: String, gesture: TimeInterval) -> Task<JSONValue, any Error> {
        Task { @MainActor in
            try await world.provider.call("cmux.stash.delete", params: ["stash": .string(stash)], context: click(gesture))
        }
    }

    static func shown(_ world: World, _ count: Int) async throws {
        for _ in 0..<1_000 where world.toasts.shown.count < count { await Task.yield() }
        try #require(world.toasts.shown.count >= count, "the provider showed \(world.toasts.shown.count) Undo toasts, not \(count)")
    }

    @Test func aToastWhoseTimeRunsOutDeletes() async throws {
        let world = Self.world()
        let call = Self.delete(world, "s1", gesture: 10)
        try await Self.shown(world, 1)
        world.toasts.shown[0].end(.timeout)
        #expect(try await call.value == ["deleted": true])
        #expect(world.deleted.calls == ["s1"])
    }

    /// One click, two deletes: the second is refused, so a page script cannot spend one gesture on
    /// many deletes.
    @Test func twoDeletesOffOneGestureRefuseTheSecond() async throws {
        let world = Self.world()
        let first = Self.delete(world, "s1", gesture: 10)
        try await Self.shown(world, 1)
        do {
            _ = try await world.provider.call("cmux.stash.delete", params: ["stash": "s2"], context: Self.click(10))
            Issue.record("a second delete off the same click went through")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(world.toasts.shown.count == 1, "the refused delete showed a toast")
        world.toasts.shown[0].end(.timeout)
        #expect(try await first.value == ["deleted": true])
        #expect(world.deleted.calls == ["s1"], "only the first click's delete went")
    }

    /// The page closes while the toast is up: nothing is deleted and the toast goes.
    @Test func closingThePageMidToastDeletesNothing() async throws {
        let world = Self.world()
        let call = Self.delete(world, "s1", gesture: 10)
        try await Self.shown(world, 1)
        world.provider.pageDidClose()
        #expect(try await call.value == ["deleted": false])
        #expect(world.toasts.shown[0].dismissed, "the Undo toast outlived its page")
        // The toast's later end cannot reach the finished call.
        world.toasts.shown[0].end(.timeout)
        #expect(world.deleted.calls.isEmpty)
    }

    /// The router cancels the call (the page closed): nothing is deleted.
    @Test func aCancelledCallDeletesNothing() async throws {
        let world = Self.world()
        let call = Self.delete(world, "s1", gesture: 10)
        try await Self.shown(world, 1)
        call.cancel()
        #expect(try await call.value == ["deleted": false])
        world.toasts.shown[0].end(.timeout)
        #expect(world.deleted.calls.isEmpty)
    }

    /// A newer toast takes the old one's place, then the person presses Undo on the new one:
    /// neither delete goes (the replacement is no confirmation of the old one).
    @Test func replaceThenUndoDeletesNeither() async throws {
        let world = Self.world()
        let old = Self.delete(world, "s1", gesture: 10)
        try await Self.shown(world, 1)
        let new = Self.delete(world, "s1", gesture: 11)
        try await Self.shown(world, 2)
        world.toasts.shown[0].end(.replaced)
        world.toasts.shown[1].end(.action)
        #expect(try await old.value == ["deleted": false])
        #expect(try await new.value == ["deleted": false])
        #expect(world.deleted.calls.isEmpty)
    }

    /// The toast's close button keeps the stash too: only the time running out commits.
    @Test func closingTheToastKeepsTheStash() async throws {
        let world = Self.world()
        let call = Self.delete(world, "s1", gesture: 10)
        try await Self.shown(world, 1)
        world.toasts.shown[0].end(.closed)
        #expect(try await call.value == ["deleted": false])
        #expect(world.deleted.calls.isEmpty)
    }

    /// Malformed `members` values: never read as every member.
    nonisolated static let malformed: [JSONValue] = [.null, "m1", ["m1", 2], [], ["m1", "m1"], [""]]

    static func refused(_ world: World, _ op: String, _ params: JSONValue, gesture: TimeInterval) async -> Bool {
        do {
            _ = try await world.provider.call(op, params: params, context: click(gesture))
            return false
        } catch let error as PageError {
            return error.code == "cmux.protocol.invalid_params"
        } catch {
            return false
        }
    }

    @Test(arguments: 0..<6)
    func aDeleteWithMalformedMembersTouchesNothing(_ index: Int) async throws {
        let world = Self.world()
        let params: JSONValue = ["stash": "s1", "members": Self.malformed[index]]
        #expect(await Self.refused(world, "cmux.stash.delete", params, gesture: 10), "\(Self.malformed[index]) was not refused")
        #expect(world.toasts.shown.isEmpty, "a malformed delete showed its Undo toast")
        #expect(world.deleted.calls.isEmpty)
    }

    @Test(arguments: 0..<6)
    func aRestoreWithMalformedMembersTouchesNothing(_ index: Int) async throws {
        let world = Self.world()
        let params: JSONValue = ["stash": "s1", "members": Self.malformed[index]]
        #expect(await Self.refused(world, "cmux.stash.restore", params, gesture: 10), "\(Self.malformed[index]) was not refused")
        #expect(world.deleted.restored.isEmpty)
    }

    /// A member id the stash does not have, or a stash the daemon does not list, is refused.
    @Test func unknownIdsAreRefused() async throws {
        let world = Self.world()
        #expect(await Self.refused(world, "cmux.stash.delete", ["stash": "s1", "members": ["m9"]], gesture: 10))
        #expect(await Self.refused(world, "cmux.stash.delete", ["stash": "s9"], gesture: 11))
        #expect(await Self.refused(world, "cmux.stash.restore", ["stash": "s1", "members": ["m1", "m9"]], gesture: 12))
        #expect(await Self.refused(world, "cmux.stash.restore", ["stash": "s1", "new_workspace": "yes"], gesture: 13))
        #expect(world.toasts.shown.isEmpty)
        #expect(world.deleted.calls.isEmpty && world.deleted.restored.isEmpty)
    }

    /// Absent `members` is every member; a valid list is that list.
    @Test func absentMembersIsEveryMemberAndAListIsThatList() async throws {
        let world = Self.world()
        _ = try await world.provider.call("cmux.stash.restore", params: ["stash": "s1", "members": ["m2"]], context: Self.click(10))
        _ = try await world.provider.call("cmux.stash.restore", params: ["stash": "s1"], context: Self.click(11))
        #expect(world.deleted.restored.map(\.1) == [["m2"], nil])
        let call = Task { @MainActor in
            try await world.provider.call("cmux.stash.delete", params: ["stash": "s1", "members": ["m1"]], context: Self.click(12))
        }
        try await Self.shown(world, 1)
        world.toasts.shown[0].end(.timeout)
        #expect(try await call.value == ["deleted": true])
        #expect(world.deleted.deletedMembers == [["m1"]])
    }
}
