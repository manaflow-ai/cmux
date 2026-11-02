import Foundation
@testable import CmuxNextSidebar
import Testing

/// `SidebarDocStore.settled()`: the completion signal a classic import waits on before it writes a
/// workspace's group, and the live-daemon tests wait on before they read the sidebar, instead of a
/// quiet window (#28425). It holds while a move or an adopt waits for its reply and ends with it.
@MainActor @Suite(.serialized) struct SidebarDocSettledTests {
    private static let section = "sec_m_s-local"
    private static let document = Data(#"""
    {"revision":"1","sections":[{"id":"sec_m_s-local","kind":{"type":"machine","session_id":"s-local"}}],
     "items":[{"id":"w_a","section":"sec_m_s-local","order":"a","body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"a"}}},
              {"id":"w_b","section":"sec_m_s-local","order":"b","body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"b"}}}]}
    """#.utf8)

    /// Answers the load at once and holds every change's reply until the test releases it.
    @MainActor private final class Remote: SidebarDocRemote {
        private var held: [CheckedContinuation<Void, Never>] = []
        private(set) var asked = 0
        var isAvailable: Bool { true }
        func get() async throws -> Data { SidebarDocSettledTests.document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { await hold() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { await hold() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { await hold() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { await hold() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { await hold() }

        func release() {
            let waiting = held
            held = []
            for reply in waiting { reply.resume() }
        }

        private func hold() async -> SidebarDocReply {
            asked += 1
            await withCheckedContinuation { held.append($0) }
            return SidebarDocReply(revision: 2, inverse: Data("[]".utf8))
        }
    }

    /// Set by a waiter once `settled()` returned.
    @MainActor private final class Returned {
        var value = false
    }

    private static func loaded() async throws -> (SidebarDocStore, Remote) {
        let remote = Remote()
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive && store.isSettled }
        try #require(store.isActive && store.isSettled, "the document never loaded")
        return (store, remote)
    }

    /// `settled()` returns only after the reply of a change sent before it was called.
    private static func expectHeld(_ store: SidebarDocStore, _ remote: Remote, _ what: String) async {
        defer { remote.release() }
        #expect(!store.isSettled, "\(what) on its way counts as settled")
        let returned = Returned()
        let waiter = Task { @MainActor in
            await store.settled()
            returned.value = true
        }
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { remote.asked == 1 }
        #expect(remote.asked == 1, "\(what) was never sent")
        for _ in 0..<20 { await Task.yield() }
        #expect(!returned.value, "settled() returned before \(what)'s reply")
        remote.release()
        await waiter.value
        #expect(returned.value && store.isSettled, "settled() did not end with \(what)'s reply")
    }

    @Test func aMoveIsInFlightUntilItsReply() async throws {
        let (store, remote) = try await Self.loaded()
        store.move(["w_b"], to: SidebarDocTarget(section: Self.section, before: "w_a"), title: "Move")
        await Self.expectHeld(store, remote, "a move")
    }

    @Test func anAdoptIsInFlightUntilItsReply() async throws {
        let (store, remote) = try await Self.loaded()
        store.adopt([SidebarDocWorkspaceRef(sessionID: "s-local", workspaceID: "c")])
        await Self.expectHeld(store, remote, "an adopt")
    }

    @Test func nothingSentIsSettledAtOnce() async throws {
        let (store, _) = try await Self.loaded()
        await store.settled()
        #expect(store.isSettled)
    }
}
