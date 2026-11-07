import Foundation
@testable import CmuxNextSidebar
import Testing

/// A change the daemon answered whose echo never came (it went to a closed connection): the next load holds it, so
/// the mirror stops replaying it. The sidebar draws names from the mirror (`SidebarMirror.projection`), so a rename
/// or a section title still replayed would hide every later one.
@MainActor @Suite struct SidebarDocMissedEchoTests {
    static let session = "s-local"

    static func document(revision: Int, name: String) -> Data {
        Data(#"""
        {"revision":"\#(revision)","sections":[{"id":"sec_m_s-local","kind":{"type":"machine","session_id":"s-local"}},
                                            {"id":"sec_c","kind":{"type":"custom"},"title":"\#(name)","shows_title":true}],
         "items":[{"id":"g_1","section":"sec_m_s-local","order":"a","body":{"type":"group","name":"\#(name)"}},
                  {"id":"l_1","section":"sec_c","order":"a","body":{"type":"url","url":"https://a.example"}},
                  {"id":"w_a","section":"sec_m_s-local","parent":"g_1","order":"a","body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"a"}}}]}
        """#.utf8)
    }

    /// Answers every change at once and sends no echo; the load serves whatever `document` is now.
    @MainActor final class Remote: SidebarDocRemote {
        var document = SidebarDocMissedEchoTests.document(revision: 1, name: "One")
        private(set) var applied = 0
        var isAvailable: Bool { true }
        func get() async throws -> Data { document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try reply() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try reply() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try reply() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try reply() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { try reply() }
        private func reply() throws -> SidebarDocReply {
            applied += 1
            return SidebarDocReply(revision: 2, inverse: Data(#"[{"op":"group.update","id":"g_1","patch":{"name":"One"}}]"#.utf8))
        }
    }

    static func groupName(_ store: SidebarDocStore) -> String? {
        store.projectionCache = nil
        let nodes = store.projection(live: [SidebarDocWorkspaceRef(sessionID: session, workspaceID: "a")])?.machines[session] ?? []
        for case let .group(group) in nodes where group.id == "g_1" { return group.name }
        return nil
    }

    static func sectionTitle(_ store: SidebarDocStore) -> String? {
        store.projectionCache = nil
        let layout = store.projection(live: [SidebarDocWorkspaceRef(sessionID: session, workspaceID: "a")])?.layout
        return layout?.sections.first { $0.id.rawValue == "sec_c" }?.title
    }

    /// A group rename stops replaying at the load.
    @Test(arguments: [
        ["op": "group.update", "id": "g_1", "patch": ["name": "Two"]],
    ] as [[String: any Sendable]])
    func aLaterRenameShowsAfterAMissedEcho(op: [String: any Sendable]) async throws {
        let shown: (SidebarDocStore) -> String? = op["op"] as? String == "group.update" ? Self.groupName : Self.sectionTitle
        let remote = Remote()
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the document never loaded")
        try store.sendChecked(ops: [op as [String: Any]], title: "Rename", undoable: false)
        #expect(shown(store) == "Two", "the pending rename does not draw")
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { remote.applied == 1 && store.isSettled }
        // Another window renames the group again; this one's echo never came either. A load brings both.
        remote.document = Self.document(revision: 3, name: "Three")
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { store.records.revision == 3 }
        try #require(store.records.revision == 3, "the second load never came")
        #expect(shown(store) == "Three", "the answered rename still replays over the loaded name")
    }
}
