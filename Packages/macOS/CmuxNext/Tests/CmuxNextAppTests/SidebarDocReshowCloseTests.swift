import Foundation
@testable import CmuxNextSidebar
import Testing

/// A placement may refresh presentation after a remote workspace leaves, before the normal live-set observation.
/// Its presentation must not erase the prior placement that identifies a real close, or turn a disconnect into one.
@MainActor @Suite(.serialized) struct SidebarDocReshowCloseTests {
    private static let ref = SidebarDocWorkspaceRef(sessionID: "remote", workspaceID: "last-member")
    private static let document = Data(#"""
    {"revision":"1","sections":[{"id":"sec_m_remote","kind":{"type":"machine","session_id":"remote"}}],
     "items":[{"id":"group","section":"sec_m_remote","order":"a","body":{"type":"group","name":"Remote group"}},
              {"id":"member","section":"sec_m_remote","parent":"group","order":"a",
               "body":{"type":"workspace","ref":{"session_id":"remote","workspace_id":"last-member"}}}]}
    """#.utf8)

    private final class Remote: SidebarDocRemote {
        var applied: [Data] = []
        var isAvailable: Bool { true }
        func get() async throws -> Data { SidebarDocReshowCloseTests.document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { reply }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { reply }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { reply }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { reply }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply {
            applied.append(ops)
            return reply
        }

        private var reply: SidebarDocReply { SidebarDocReply(revision: 2, inverse: Data("[]".utf8)) }
    }

    @Test(arguments: [true, false])
    func presentationRefreshPreservesCloseDetection(remoteStillConnected: Bool) async throws {
        let remote = Remote()
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive)
        store.show(live: [Self.ref], connectedRemotes: ["remote"])
        try #require(store.shown?.items[Self.ref] == "member")

        // A local placement's immediate reproject sees the remote member gone before the regular show catches up.
        store.reshow(live: [])
        try #require(store.shown?.items[Self.ref] == nil)
        store.show(live: [], connectedRemotes: remoteStillConnected ? ["remote"] : [])
        let projection = try #require(store.projection(live: []))
        let hasGroup = projection.machines["remote"]?.contains { node in
            if case let .group(group) = node { return group.id == "group" }
            return false
        } ?? false

        if remoteStillConnected {
            #expect(!hasGroup, "closing the last member must remove its empty ancestor group")
            await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !remote.applied.isEmpty }
            let data = try #require(remote.applied.first, "the connected remote close was never sent")
            let ops = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(ops.first?["op"] as? String == "close")
            let refs = try #require(ops.first?["refs"] as? [[String: String]])
            #expect(refs == [["session_id": "remote", "workspace_id": "last-member"]])
        } else {
            #expect(hasGroup, "a disconnect must preserve the remote document items")
            #expect(store.lastIntentKey == nil, "a disconnected remote must not get a close intent")
        }
    }
}
