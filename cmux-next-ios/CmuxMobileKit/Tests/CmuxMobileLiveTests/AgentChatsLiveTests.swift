import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The agent chats rows of the parity matrix (cmux#25834 slice C) at the backend's boundary:
/// the lines a phone sends to the Mac's daemon and acpmux for the Chats list, Open in Tab,
/// Open in New Workspace, Unarchive, Open Chat Folder in Terminal and Mark All as Read.
@MainActor
@Suite struct AgentChatsLiveTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var daemon: [[String: Any]] = []
        private var acpmux: [(String, [String: Any])] = []
        func daemon(_ object: [String: Any]) { lock.withLock { daemon.append(object) } }
        func acpmux(_ method: String, _ params: [String: Any]) { lock.withLock { acpmux.append((method, params)) } }
        var daemonLines: [[String: Any]] { lock.withLock { daemon } }
        var acpmuxCalls: [(String, [String: Any])] { lock.withLock { acpmux } }
        /// The daemon's mutations, in order (reads left out).
        /// The daemon's v12 mutations, in order (reads and resource API reads left out).
        var mutations: [[String: Any]] {
            daemonLines.filter { line in
                guard let cmd = line["cmd"] as? String else { return false }
                return !["list-workspaces", "subscribe", "set-client-info", "identify", "list-agents", "list-personal"].contains(cmd)
            }
        }
    }

    /// wk1: s10 a terminal, s11 the chat `sess-a` (folder /Users/me/src/app), s12 a terminal with
    /// an unread notification, s13 one with a read notification, s14 the chat `sess-p` (a peer's).
    nonisolated static let tree = #"""
    {"workspaces":[
      {"id":1,"key":"wk1","name":"main","screens":[{"active":true,"active_pane":4,"panes":[{"id":4,"active_tab":0,"tabs":[
        {"surface":10,"kind":"pty","title":"zsh","dead":false,"terminal_id":"t10","cwd":"/Users/me/src/app"},
        {"surface":11,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-a","harness":"claude"}}},
        {"surface":12,"kind":"pty","title":"zsh","dead":false,"terminal_id":"t12","notification":{"notification":5,"unread":true}},
        {"surface":13,"kind":"pty","title":"zsh","dead":false,"terminal_id":"t13","notification":{"notification":4,"unread":false}},
        {"surface":14,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-p","harness":"claude"}}}]}]}]}
    ]}
    """#

    nonisolated static func daemon(_ seen: Seen) -> MockMacLink {
        MockMacLink { _, data in
            data.split(separator: 0x0A).compactMap { request -> Data? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                      let id = object["id"] as? String else { return nil }
                seen.daemon(object)
                let line: String
                switch object["cmd"] as? String ?? "" {
                case "list-workspaces":
                    line = #"{"id":"\#(id)","ok":true,"data":\#(tree.replacingOccurrences(of: "\n", with: ""))}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                case "new-conversation-tab":
                    line = #"{"id":"\#(id)","ok":true,"data":{"surface":11}}"#
                case "new-tab":
                    line = #"{"id":"\#(id)","ok":true,"data":{"surface":10}}"#
                case "create-workspace":
                    line = #"{"id":"\#(id)","ok":true,"data":{"workspace":1,"key":"wk1"}}"#
                default:
                    line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                }
                return Data(line.utf8) + Data([0x0A])
            }
        }
    }

    /// acpmux: `sess-a` in /Users/me/src/app (plus `sess-q`, whose folder could edit a shell line,
    /// and `sess-p`, which runs on a peer: its folder is that machine's).
    nonisolated static func acpmux(_ seen: Seen) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any] ?? [:]
            seen.acpmux(method, params)
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"sess-a","harness":"claude","cwd":"/Users/me/src/app","status":"idle"},{"sessionId":"sess-q","harness":"claude","cwd":"/Users/me/a\u0007b","status":"idle"},{"sessionId":"sess-p","harness":"claude","cwd":"/Users/them/src/app","peer":"other-mac","status":"idle"}]}"#)]
            case "_acpmux/sessions":
                return [reply(#"""
                {"sessions":[
                  {"sessionId":"sess-a","title":"Fix the build","harness":"claude","cwd":"/Users/me/src/app","status":"running","updatedAt":1700000000000,"startedBy":null,"tags":{}},
                  {"sessionId":"sess-b","title":null,"lastPrompt":"Why is CI red?","harness":"codex","cwd":"/Users/me/src/web","status":"idle","tags":{"archived":"1699"}},
                  {"sessionId":"sess-p","title":"On the other Mac","harness":"claude","cwd":"/x","status":"idle","peer":"huge-blue","tags":{}},
                  {"sessionId":"sess-s","title":"Side","harness":"claude","cwd":"/x","status":"idle","tags":{"side":"sess-a"}},
                  {"sessionId":"sess-c","title":"Child","harness":"claude","cwd":"/x","status":"idle","spawnedBy":"sess-a","tags":{}},
                  {"sessionId":"sess-t","title":"Sub-session","harness":"codex","cwd":"/x","status":"idle","startedBy":"sess-gone","depth":1,"tags":{}}
                ],"nextCursor":"k1.2"}
                """#.replacingOccurrences(of: "\n", with: ""))]
            case "_acpmux/archive":
                let archived = params["archived"] as? Bool == true
                return [reply(#"{"sessionId":"sess-b","title":"Why","harness":"codex","cwd":"/Users/me/src/web","status":"idle","tags":\#(archived ? #"{"archived":"1"}"# : "{}")}"#)]
            default:
                return [reply("{}")]
            }
        }
    }

    /// The backend holds its acpmux hub weakly (the Mac session owns it): the suite keeps it.
    final class Hold: @unchecked Sendable { var hub: AcpmuxHub? }
    let hold = Hold()

    func connected(_ seen: Seen) async throws -> (LiveWorkspaceCreationBackend, WorkspaceSync) {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await Self.daemon(seen).openChannel(service: "daemon", args: [:]), macID: "m")
        let hub = AcpmuxHub()
        await hub.bind(try await Self.acpmux(seen).openChannel(service: "acpmux", args: [:]))
        hold.hub = hub
        #expect(hub.isReady)
        return (LiveWorkspaceCreationBackend(sync: sync, link: controller, acpmux: hub), sync)
    }

    func workspace(_ sync: WorkspaceSync) throws -> Workspace {
        try #require(sync.tree?.workspaces.first { $0.id == "wk1" })
    }

    @Test func theListKeepsThisMacsChatsAndMarksArchivedOnes() async throws {
        let seen = Seen()
        let (backend, _) = try await connected(seen)
        #expect(backend.canListAgentChats(on: "m"))
        let page = try await backend.agentChats(on: "m", cursor: nil)
        #expect(page.chats.map(\.id) == ["sess-a", "sess-b"])
        #expect(page.nextCursor == "k1.2")
        #expect(page.chats[0].displayTitle == "Fix the build")
        #expect(page.chats[0].archived == false)
        #expect(page.chats[1].archived == true)
        // No title: the first prompt names it, as acpmux's lists do.
        #expect(page.chats[1].displayTitle == "Why is CI red?")
        let request = try #require(seen.acpmuxCalls.last { $0.0 == "_acpmux/sessions" })
        #expect((request.1["limit"] as? NSNumber)?.intValue == LiveWorkspaceCreationBackend.chatPageSize)
        #expect(request.1["cursor"] == nil)
        _ = try await backend.agentChats(on: "m", cursor: "k1.2")
        #expect(seen.acpmuxCalls.last { $0.0 == "_acpmux/sessions" }?.1["cursor"] as? String == "k1.2")
    }

    @Test func openInTabShowsTheTabThatHasItOrOpensOneInTheActivePane() async throws {
        let seen = Seen()
        let (backend, sync) = try await connected(seen)
        let ws = try workspace(sync)
        let shown = AgentChatListing(id: "sess-a", title: "Fix", harness: "claude", cwd: "/x", status: "idle", updatedAt: nil, archived: false)
        #expect(try await backend.openAgentChat(shown, in: ws).id == "s11")
        #expect(seen.mutations.isEmpty)

        let other = AgentChatListing(id: "sess-b", title: "Why", harness: "codex", cwd: "/x", status: "idle", updatedAt: nil, archived: true)
        _ = try await backend.openAgentChat(other, in: ws)
        let line = try #require(seen.mutations.first)
        #expect(line["cmd"] as? String == "new-conversation-tab")
        #expect(line["pane"] as? Int == 4)
        let session = try #require(line["agent_session"] as? [String: Any])
        #expect(session["session"] as? String == "sess-b")
        #expect(session["harness"] as? String == "codex")
        // The phone never names a host, folder or command (cmux-mobile-host sets the host).
        #expect(Set(line.keys) == ["id", "cmd", "pane", "agent_session"])
        #expect(Set(session.keys) == ["session", "harness"])
    }

    @Test func openInNewWorkspaceMakesAWorkspaceWhoseTabIsTheChat() async throws {
        let seen = Seen()
        let (backend, _) = try await connected(seen)
        let chat = AgentChatListing(id: "sess-b", title: "Why is CI red?", harness: "codex", cwd: "/x", status: "idle", updatedAt: nil, archived: false)
        let created = try await backend.openAgentChatInNewWorkspace(chat, on: "m")
        #expect(created.id == "wk1")
        let lines = seen.mutations
        #expect(lines.map { $0["cmd"] as? String } == ["create-workspace", "new-conversation-tab"])
        #expect(lines[0]["name"] as? String == "Why is CI red?")
        #expect(lines[1]["workspace"] as? Int == 1)
        #expect((lines[1]["agent_session"] as? [String: Any])?["session"] as? String == "sess-b")
    }

    @Test func unarchiveRemovesTheTagOnTheMac() async throws {
        let seen = Seen()
        let (backend, _) = try await connected(seen)
        let chat = AgentChatListing(id: "sess-b", title: "Why", harness: "codex", cwd: "/x", status: "idle", updatedAt: nil, archived: true)
        let now = try await backend.setAgentChatArchived(chat, archived: false, on: "m")
        let call = try #require(seen.acpmuxCalls.last { $0.0 == "_acpmux/archive" })
        #expect(call.1["sessionId"] as? String == "sess-b")
        #expect(call.1["archived"] as? Bool == false)
        #expect(now.archived == false)
        let again = try await backend.setAgentChatArchived(now, archived: true, on: "m")
        #expect(again.archived == true)
    }

    @Test func openChatFolderInTerminalTypesASafeCdBesideTheChat() async throws {
        let seen = Seen()
        let (backend, sync) = try await connected(seen)
        let ws = try workspace(sync)
        let chat = try #require(ws.tabs.first { $0.id == "s11" })
        _ = try await backend.openChatFolderInTerminal(chat, in: ws)
        let lines = seen.mutations
        #expect(lines.map { $0["cmd"] as? String } == ["new-tab", "send"])
        #expect(lines[0]["pane"] as? Int == 4)
        #expect(Set(lines[0].keys) == ["id", "cmd", "pane"])
        #expect(lines[1]["surface"] as? Int == 10)
        #expect(lines[1]["text"] as? String == "cd '/Users/me/src/app' && clear\n")
    }

    @Test func aPeersChatFolderIsNeverTypedHereEvenWhenWatched() async throws {
        let seen = Seen()
        let (backend, sync) = try await connected(seen)
        // `_acpmux/watch` listed it, folder and all: the peer, not the cached folder, decides.
        #expect(hold.hub?.sessions["sess-p"]?.peer == "other-mac")
        let ws = try workspace(sync)
        let chat = try #require(ws.tabs.first { $0.id == "s14" })
        await #expect(throws: LiveWorkspaceCreationBackend.remoteChatFolder) {
            try await backend.openChatFolderInTerminal(chat, in: ws)
        }
        #expect(seen.mutations.isEmpty)
    }

    @Test func aFolderThatCouldEditTheShellLineIsNeverTyped() async throws {
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/Users/me/a\u{7}b") == nil)
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/Users/me/it's") == "cd '/Users/me/it'\\''s' && clear\n")
    }

    @Test func markAllAsReadAcksOnlyTheUnreadTabs() async throws {
        let seen = Seen()
        let (backend, _) = try await connected(seen)
        #expect(try await backend.markAllNotificationsRead(on: "m") == 1)
        let acks = seen.mutations.filter { $0["cmd"] as? String == "ack-tab-notifications" }
        #expect(acks.map { $0["surface"] as? Int } == [12])
    }
}
