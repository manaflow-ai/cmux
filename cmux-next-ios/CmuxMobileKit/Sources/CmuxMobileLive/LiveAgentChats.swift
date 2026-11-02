import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation

/// The Mac's agent chats from a phone, with lines the phone already sends (no host or
/// acpmux guard change):
/// - the list: acpmux `_acpmux/sessions {limit, cursor}` (a read acpmux's remote guard
///   serves a Web connection), keeping the chats this Mac's acpmux runs that a chat list
///   shows: no peer's session (another machine's), no side chat, no subagent session;
/// - Open in Tab: daemon `new-conversation-tab {pane, agent_session}` (the Mac's
///   `agent.openSessionTab`), or the tab that already shows the chat in that workspace;
/// - Open in New Workspace: `create-workspace {name}`, then `new-conversation-tab
///   {workspace, agent_session}` (the Mac's `agent.openSessionWorkspace`);
/// - Archive / Unarchive: acpmux `_acpmux/archive {sessionId, archived}`, as the Mac's chat menu;
/// - Open Chat Folder in Terminal: `new-tab {pane}` in the chat's pane, then
///   `cd '<folder>' && clear` typed into it (`changeDirectoryLine`, which refuses a folder
///   that could edit the shell line), as Duplicate Workspace and Open Folder do.
extension LiveWorkspaceCreationBackend: AgentChatsBackend {
    /// The page size of the Chats list.
    nonisolated static let chatPageSize = 100

    public func canListAgentChats(on macID: String) -> Bool {
        canManage(on: macID) && acpmux?.isReady == true
    }

    public func agentChats(on macID: String, cursor: String?) async throws -> AgentChatPage {
        let acpmux = try readyAcpmux(macID)
        var params: [String: JSONValue] = ["limit": .number(Double(Self.chatPageSize))]
        if let cursor { params["cursor"] = .string(cursor) }
        let reply: JSONValue
        do {
            reply = try await acpmux.request("_acpmux/sessions", .object(params), timeout: .seconds(20))
        } catch let error as AcpmuxConnection.RPCError {
            throw WorkspaceCreationError(error.message, isForPerson: true)
        }
        return Self.chatPage(reply)
    }

    /// A `_acpmux/sessions` reply as the list's page.
    nonisolated static func chatPage(_ reply: JSONValue) -> AgentChatPage {
        let chats = (reply["sessions"]?.arrayValue ?? []).compactMap(listing)
        return AgentChatPage(chats: chats, nextCursor: reply["nextCursor"]?.stringValue)
    }

    /// One acpmux `SessionSummary` as a listed chat; nil for one a chat list leaves out: a
    /// peer's session (it runs on another machine, which this Mac's tab cannot show), a side
    /// chat (`side` tag) and a session another chat's agent started (`spawnedBy`, or a
    /// sub-session's `startedBy`, which stays set after its parent closes: it lists under its parent).
    nonisolated static func listing(_ value: JSONValue) -> AgentChatListing? {
        // A chat with no harness names no agent a tab of it could run.
        guard let id = value["sessionId"]?.stringValue, !id.isEmpty,
              let harness = value["harness"]?.stringValue, !harness.isEmpty else { return nil }
        if let peer = value["peer"]?.stringValue, !peer.isEmpty { return nil }
        let tags = value["tags"]
        if tags?["side"] != nil { return nil }
        for parent in ["spawnedBy", "startedBy"] where value[parent]?.stringValue?.isEmpty == false { return nil }
        let archived = tags?["archived"] != nil || value["archived"] == .bool(true)
        let title = value["title"]?.stringValue ?? value["lastPrompt"]?.stringValue
        return AgentChatListing(
            id: id, title: title.map { String($0.prefix(200)) }, harness: harness,
            cwd: value["cwd"]?.stringValue ?? "", status: value["status"]?.stringValue ?? "idle",
            updatedAt: value["updatedAt"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) },
            archived: archived, lastPrompt: value["lastPrompt"]?.stringValue.map { String($0.prefix(500)) })
    }

    public func openAgentChat(_ chat: AgentChatListing, in workspace: Workspace) async throws -> WorkspaceTab {
        guard canManage(on: workspace.macID), let client = sync.daemon, let tree = sync.tree else {
            throw WorkspaceCreationError("Not connected")
        }
        // A tab of this workspace already shows it: that tab, never a second one.
        if let shown = workspace.tabs.first(where: { tree.agentTabs[$0.id]?.session == chat.id }) { return shown }
        guard let pane = tree.panes[workspace.id] else {
            throw WorkspaceCreationError("The Mac hasn't listed this workspace's panes")
        }
        do {
            let reply = try await client.request("new-conversation-tab", params: [
                "pane": pane, "agent_session": ["harness": chat.harness, "session": chat.id],
            ])
            return try await listedTab(surfaceIn: reply, workspace: workspace.id)
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    public func openAgentChatInNewWorkspace(_ chat: AgentChatListing, on macID: String) async throws -> Workspace {
        guard canManage(on: macID), let client = sync.daemon else { throw WorkspaceCreationError("Not connected") }
        do {
            let created = try WorkspaceSync.check(await client.request("create-workspace", params: ["name": String(chat.displayTitle.prefix(80))]))
            let data = created["data"] as? [String: Any] ?? created
            guard let id = data["workspace"] as? Int, let key = data["key"] as? String else {
                // Never an empty workspace left behind.
                if let key = data["key"] as? String { _ = try? await client.request("close-workspace", params: ["key": key]) }
                throw WorkspaceCreationError("The Mac didn't say which workspace it created")
            }
            do {
                try WorkspaceSync.check(await client.request("new-conversation-tab", params: [
                    "workspace": id, "agent_session": ["harness": chat.harness, "session": chat.id],
                ]))
            } catch {
                // An empty workspace is never left behind.
                _ = try? await client.request("close-workspace", params: ["key": key])
                throw error
            }
            let tree = try await sync.listNow()
            guard let workspace = tree.workspaces.first(where: { $0.id == key }) else {
                throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
            }
            return workspace
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    public func setAgentChatArchived(_ chat: AgentChatListing, archived: Bool, on macID: String) async throws -> AgentChatListing {
        let acpmux = try readyAcpmux(macID)
        let reply: JSONValue
        do {
            reply = try await acpmux.request("_acpmux/archive", .object(["sessionId": .string(chat.id), "archived": .bool(archived)]),
                                             timeout: .seconds(20))
        } catch let error as AcpmuxConnection.RPCError {
            throw WorkspaceCreationError(error.message, isForPerson: true)
        }
        // acpmux answers with the session's summary, tags included.
        if let now = Self.listing(reply) { return now }
        var now = chat
        now.archived = archived
        return now
    }

    /// Stop: `session/cancel` as a request, so acpmux's refusal (a chat the Mac started,
    /// `remote.session_cancel_ownership`) comes back instead of being dropped.
    public func stopAgentChat(_ chat: AgentChatListing, on macID: String) async throws {
        let acpmux = try readyAcpmux(macID)
        do {
            _ = try await acpmux.request("session/cancel", .object(["sessionId": .string(chat.id)]), timeout: .seconds(20))
        } catch let error as AcpmuxConnection.RPCError {
            throw WorkspaceCreationError(error.message, isForPerson: true)
        }
    }

    public func openChatFolderInTerminal(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        guard canManage(on: workspace.macID), let client = sync.daemon, let tree = sync.tree else {
            throw WorkspaceCreationError("Not connected")
        }
        guard let session = tree.agentTabs[tab.id]?.session else {
            throw WorkspaceCreationError("This chat hasn't started.", isForPerson: true)
        }
        guard let place = tree.tabPlaces[tab.id] ?? tree.panes[workspace.id].map({ DaemonTree.TabPlace(pane: $0, index: 0) }) else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        let folder = try await chatFolder(session: session, macID: workspace.macID)
        guard let line = Self.changeDirectoryLine(folder) else {
            throw WorkspaceCreationError(Self.untypableFolder, isForPerson: true)
        }
        do {
            let reply = try await client.request("new-tab", params: ["pane": place.pane])
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            try WorkspaceSync.check(await client.request("send", params: ["surface": surface, "text": line]))
            return try await listedTab(DaemonTree.tabID(surface: surface), workspace: workspace.id)
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    nonisolated static let remoteChatFolder = WorkspaceCreationError(
        "This chat runs on another computer, so its folder isn't on this Mac.", isForPerson: true)

    nonisolated static let untypableFolder = "This chat's folder has characters that can't be typed safely into a terminal. Open a terminal and change to it yourself."

    /// The chat's folder on this Mac: the watched session's, else `_acpmux/info`'s. A chat that
    /// runs on another machine (an acpmux peer's) has its folder there, never typed here.
    private func chatFolder(session: String, macID: String) async throws -> String {
        let acpmux = try readyAcpmux(macID)
        // `_acpmux/watch` lists peers' sessions too: a cached one is checked as `_acpmux/info`'s.
        if let watched = acpmux.sessions[session] {
            if watched.peer != nil { throw Self.remoteChatFolder }
            if !watched.cwd.isEmpty { return watched.cwd }
        }
        let info: JSONValue
        do {
            info = try await acpmux.request("_acpmux/info", .object(["sessionId": .string(session)]), timeout: .seconds(15))
        } catch let error as AcpmuxConnection.RPCError {
            throw WorkspaceCreationError(error.message, isForPerson: true)
        }
        if let peer = info["peer"]?.stringValue, !peer.isEmpty { throw Self.remoteChatFolder }
        guard let cwd = info["cwd"]?.stringValue, !cwd.isEmpty else {
            throw WorkspaceCreationError("The Mac didn't say which folder this chat is in.", isForPerson: true)
        }
        return cwd
    }

    private func readyAcpmux(_ macID: String) throws -> AcpmuxHub {
        guard canManage(on: macID) else { throw WorkspaceCreationError("Not connected") }
        guard let acpmux, acpmux.isReady else {
            throw WorkspaceCreationError("Agents on this Mac aren't connected. Try again in a moment.", isForPerson: true)
        }
        return acpmux
    }

    /// The tab a daemon reply names (`data.surface`), once the Mac lists it.
    private func listedTab(surfaceIn reply: Data, workspace: String) async throws -> WorkspaceTab {
        guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
            throw WorkspaceCreationError("The Mac didn't say which tab it opened")
        }
        return try await listedTab(DaemonTree.tabID(surface: surface), workspace: workspace)
    }

    private func listedTab(_ id: String, workspace: String) async throws -> WorkspaceTab {
        let tree = try await sync.listNow()
        guard let tab = tree.workspaces.first(where: { $0.id == workspace })?.tabs.first(where: { $0.id == id })
            ?? tree.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else {
            throw WorkspaceCreationError("The new tab didn't appear on the Mac")
        }
        return tab
    }
}
