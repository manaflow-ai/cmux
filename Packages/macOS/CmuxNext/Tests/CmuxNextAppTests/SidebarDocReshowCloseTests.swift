import Foundation
@testable import CmuxNextSidebar
import Testing

/// A placement may refresh presentation after a remote workspace leaves, before the normal live-set observation.
/// Its presentation must not erase the prior placement that identifies a real close, or turn a disconnect into one.
@MainActor @Suite(.serialized) struct SidebarDocReshowCloseTests {
    private static let ref = SidebarDocWorkspaceRef(sessionID: "remote", workspaceID: "last-member")
    private static func document(keepsClosed: Bool) -> Data { Data(#"""
    {"revision":"1","sections":[{"id":"sec_m_remote","keeps_closed":\#(keepsClosed),"kind":{"type":"machine","session_id":"remote"}}],
     "items":[{"id":"group","section":"sec_m_remote","order":"a","body":{"type":"group","name":"Remote group"}},
              {"id":"member","section":"sec_m_remote","parent":"group","order":"a",
               "body":{"type":"workspace","ref":{"session_id":"remote","workspace_id":"last-member"}}}]}
    """#.utf8) }

    private final class Remote: SidebarDocRemote {
        let keepsClosed: Bool
        init(keepsClosed: Bool) { self.keepsClosed = keepsClosed }
        var applied: [Data] = []
        var isAvailable: Bool { true }
        func get() async throws -> Data { SidebarDocReshowCloseTests.document(keepsClosed: keepsClosed) }
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

    @Test(arguments: [true, false], [true, false])
    func presentationRefreshPreservesCloseDetection(remoteStillConnected: Bool, keepsClosed: Bool) async throws {
        let remote = Remote(keepsClosed: keepsClosed)
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive)
        store.show(live: [Self.ref], connectedRemotes: ["remote"])
        try #require(store.shown?.items[Self.ref] == "member")

        // A local placement's immediate reproject sees the remote member gone before the regular show catches up.
        store.reshow(live: [])
        try #require((store.shown?.items[Self.ref] != nil) == keepsClosed)
        store.show(live: [], connectedRemotes: remoteStillConnected ? ["remote"] : [])
        let projection = try #require(store.projection(live: []))
        let hasGroup = projection.machines["remote"]?.contains { node in
            if case let .group(group) = node { return group.id == "group" }
            return false
        } ?? false

        if remoteStillConnected && !keepsClosed {
            #expect(hasGroup, "closing the last member must preserve its empty ancestor group")
            await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !remote.applied.isEmpty }
            let data = try #require(remote.applied.first, "the connected remote close was never sent")
            let ops = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(ops.count == 1)
            #expect(ops.first?["op"] as? String == "item.delete")
            #expect(ops.first?["id"] as? String == "member")
        } else {
            #expect(hasGroup, "disconnects and sections that keep closed members preserve their groups")
            #expect(store.lastIntentKey == nil, "a disconnected or retained member needs no deletion")
        }
    }
}
