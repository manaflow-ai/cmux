@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A Cloud VM chat's child chats (its sub-sessions, `acpmux new` chats) on the Mac: the chat's
/// remote wire lists them with the chat in `_acpmux/watch` from the VM daemon's
/// `agent-session-children`, so its Subagents summary shows them; their parents feed the sidebar's
/// session tree; and a row opens a child beside the chat.
@MainActor @Suite(.serialized) struct RemoteChildSessionsTests {
    /// A daemon attachment of chat `parent` whose machine started `children` from it.
    private nonisolated final class FakeClient: AgentSessionRemoteClient, @unchecked Sendable {
        let parent: String
        let listed: [[String: Any]]
        let isReadOnly = false
        init(parent: String, children: [[String: Any]]) {
            self.parent = parent
            listed = children
        }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            RemoteAcpmuxWire.json(["session": ["sessionId": parent, "status": "idle"], "events": [], "hasMore": false, "lastSeq": 0])
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data("{}".utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data("{}".utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
        func children() async throws -> Data { RemoteAcpmuxWire.json(["sessions": listed]) }
    }

    /// The reply of the wire's `_acpmux/watch`.
    private static func watch(_ wire: RemoteAcpmuxWire) async throws -> [String: Any] {
        let (frames, continuation) = AsyncStream.makeStream(of: String.self)
        try await wire.open(onFrame: { continuation.yield($0) }, onClose: { _, _ in continuation.finish() })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"_acpmux/watch","params":{"enabled":true}}"#) { _ in }
        for await frame in frames {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            if object["id"] as? Int == 7 { return try #require(object["result"] as? [String: Any]) }
        }
        throw CancellationError()
    }

    @Test func theChatsWatchListsItsChildrenAndTheirParentsAreNoted() async throws {
        let client = FakeClient(parent: "vm-chat", children: [
            ["sessionId": "vm-child", "startedBy": "vm-chat", "status": "running"],
            ["sessionId": "vm-spawned", "spawnedBy": "vm-chat"],
            ["sessionId": "vm-grandchild", "startedBy": "vm-child"],
            // The daemon never names the chat itself as a child; the wire drops it if it did.
            ["sessionId": "vm-chat"],
        ])
        let wire = RemoteAcpmuxWire(client: client, session: "vm-chat")
        let reply = try await Self.watch(wire)
        let ids = (reply["sessions"] as? [[String: Any]])?.compactMap { $0["sessionId"] as? String }
        #expect(ids == ["vm-chat", "vm-child", "vm-spawned", "vm-grandchild"])
        #expect(reply["tabSessionId"] as? String == "vm-chat")
        // The note lands on the main actor after the reply.
        for _ in 0..<50 where RemoteAgentSessionLinks.shared.parents["vm-grandchild"] == nil { await Task.yield() }
        let links = RemoteAgentSessionLinks.shared
        #expect(links.parents["vm-child"] == "vm-chat")
        #expect(links.parents["vm-spawned"] == "vm-chat")
        #expect(links.descends("vm-grandchild", from: "vm-chat"))
        #expect(!links.descends("vm-chat", from: "vm-child"))
        wire.cancel(code: 1000, reason: "done")
    }

    /// A tab that names its chat by another id than acpmux's (a session name, or a chat rebound on
    /// that machine since the page got its id): the watch says which session the daemon attached as
    /// the tab's, so the page opens it instead of saying "This chat isn't available".
    @Test func theWatchNamesTheSessionTheDaemonAttachedForTheTab() async throws {
        let client = FakeClient(parent: "acp-id-1", children: [])
        let wire = RemoteAcpmuxWire(client: client, session: "lane/review")
        let reply = try await Self.watch(wire)
        #expect((reply["sessions"] as? [[String: Any]])?.compactMap { $0["sessionId"] as? String } == ["acp-id-1"])
        #expect(reply["tabSessionId"] as? String == "acp-id-1")
        wire.cancel(code: 1000, reason: "done")
    }

    @Test func linksKeepOneParentEachAndALoopEnds() {
        let links = RemoteAgentSessionLinks()
        links.note([["sessionId": "a", "startedBy": "b"], ["sessionId": "b", "spawnedBy": "a"],
                    ["sessionId": "self", "startedBy": "self"], ["sessionId": "", "startedBy": "x"], ["startedBy": "x"]])
        #expect(links.parents == ["a": "b", "b": "a"])
        #expect(!links.descends("a", from: "root"), "a loop of links ends")
    }

    /// The sidebar's tree nests a workspace showing a VM child chat under the one showing its
    /// parent, from the parents the VM's daemon listed; a chat of this Mac still follows its lane.
    @Test func aRemoteChildsWorkspaceNestsUnderItsParents() {
        let parent = WorkspaceID("ws-parent"), child = WorkspaceID("ws-child"), other = WorkspaceID("ws-other")
        let vm = "registry:vm-store"
        let chats: [(WorkspaceID, [AgentSessionRef])] = [
            (parent, [AgentSessionRef(host: vm, session: "vm-chat")]),
            (child, [AgentSessionRef(host: vm, session: "vm-child")]),
            (other, [AgentSessionRef(host: vm, session: "vm-other")]),
        ]
        let pass = SidebarSessionTreeFeed.pass(chats, lanes: [:], remoteParents: ["vm-child": "vm-chat"],
                                               localHost: "install:mac", pullRequests: [:])
        #expect(pass.state.parents == [child: parent])
        let none = SidebarSessionTreeFeed.pass(chats, lanes: [:], localHost: "install:mac", pullRequests: [:])
        #expect(none.state.parents.isEmpty)
    }

    /// A Subagents row of a chat on another machine opens a child that chat started there beside
    /// it; never a session that machine did not list under the chat.
    @Test func aRemoteChatOpensItsListedChildBesideIt() async {
        RemoteAgentSessionLinks.shared.note([["sessionId": "vm-row-child", "startedBy": "vm-row-chat"]])
        let model = AgentPaneModel(host: NoHost(), sessionId: "vm-row-chat")
        model.remoteChat = true
        let opened = Opened()
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openSide: { _, fork in opened.ids.append(fork) })
        let side = { (session: String) in AgentPaneRequest(body: ["method": "chat.sideChat", "params": ["sessionId": session]]) }
        let child = await model.respond(to: side("vm-row-child"))
        let unlisted = await model.respond(to: side("vm-unlisted"))
        #expect(child["ok"] as? Bool == true)
        #expect(unlisted["ok"] as? Bool == false)
        #expect(opened.ids == ["vm-row-child"])
        model.remoteChat = false
        let local = await model.respond(to: side("vm-row-child"))
        #expect(local["ok"] as? Bool == false, "only a chat on another machine")
    }

    @MainActor private final class Opened { var ids: [String] = [] }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
