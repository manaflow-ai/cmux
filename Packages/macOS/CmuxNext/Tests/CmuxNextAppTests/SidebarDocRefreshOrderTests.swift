import Foundation
@testable import CmuxNextSidebar
import Testing

/// `sidebar.get` can answer after session.events has already delivered a newer document.
@MainActor @Suite(.serialized)
struct SidebarDocRefreshOrderTests {
    private static let document = Data(#"""
    {"revision":"1","sections":[{"id":"sec_m_s-local","kind":{"type":"machine","session_id":"s-local"}}],
     "items":[{"id":"w_a","section":"sec_m_s-local","order":"b","body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"a"}}},
              {"id":"w_b","section":"sec_m_s-local","order":"a","body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"b"}}}]}
    """#.utf8)

    private static let newer = Data(#"""
    {"changes":[{"kind":"state_upsert","resource":"sidebar_doc","id":"doc",
                 "value":{"revision":"2","previous_revision":"1"}},
                {"kind":"state_upsert","resource":"sidebar_item","id":"w_a",
                 "value":{"id":"w_a","section":"sec_m_s-local","order":"0",
                          "body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"a"}}}},
                {"kind":"state_upsert","resource":"sidebar_item","id":"w_c",
                 "value":{"id":"w_c","section":"sec_m_s-local","order":"c",
                          "body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"c"}}}}]}
    """#.utf8)

    private final class Remote: SidebarDocRemote {
        let reloadStarted = AsyncStream<Void>.makeStream()
        private var gets = 0
        private var held: CheckedContinuation<Data, Never>?
        var isAvailable: Bool { true }

        func get() async throws -> Data {
            gets += 1
            if gets == 1 { return SidebarDocRefreshOrderTests.document }
            return await withCheckedContinuation {
                held = $0
                reloadStarted.continuation.yield(())
            }
        }

        func release() {
            let pending = held
            held = nil
            pending?.resume(returning: SidebarDocRefreshOrderTests.document)
        }

        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { throw CancellationError() }
    }

    private static func order(_ store: SidebarDocStore, live: [String]) -> [String] {
        store.reshow(live: live.map { SidebarDocWorkspaceRef(sessionID: "s-local", workspaceID: $0) })
        return store.shown?.machines["s-local"]?.compactMap { node in
            if case let .workspace(ref, _) = node { return ref.workspaceID }
            return nil
        } ?? []
    }

    @Test func anOlderRefreshReplyKeepsNewerStreamOrderAndItems() async throws {
        let remote = Remote()
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await store.settled()
        try #require(store.isActive)
        #expect(Self.order(store, live: ["a", "b"]) == ["b", "a"])

        var requested = remote.reloadStarted.stream.makeAsyncIterator()
        store.refresh()
        _ = await requested.next()
        defer { remote.release() }
        // The get captured revision 1. Before its answer is delivered, the stream
        // carries revision 2: it fixes the order and adds the next imported workspace.
        store.receive(batch: Self.newer)
        remote.release()
        await store.settled()

        #expect(store.records.revision == 2, "the reload replaced newer confirmed document records")
        #expect(Self.order(store, live: ["a", "b", "c"]) == ["a", "b", "c"],
                "the reload lost the stream's ordering or newly imported workspace")
    }
}
