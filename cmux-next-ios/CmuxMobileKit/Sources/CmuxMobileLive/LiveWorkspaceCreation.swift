import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import OSLog

private let creationLog = Logger(subsystem: "dev.cmux.mobile", category: "creation")

/// Creates workspaces and tabs on the linked Mac's cmux-tui daemon. The
/// phone's `daemon` lane (cmux-mobile-host policy) allows `new-workspace {name}`,
/// `new-tab`, `new-browser-tab`, `close-surface` and an agent
/// `new-conversation-tab`, but never a working directory (`cwd`), so the
/// long-press menu offers no recent directories and no git clone.
@MainActor
public final class LiveWorkspaceCreationBackend: WorkspaceCreationBackend {
    let sync: WorkspaceSync
    private let link: LinkController
    /// Starts the agent session behind a new agent tab (nil: no agent tabs).
    private weak var acpmux: AcpmuxHub?

    /// The capabilities each Mac's `version` service reported (nil: not known yet).
    public var capabilities: @MainActor (String) -> Set<String>? = { _ in nil }

    /// Whether a Mac streams browser tabs: it said `browser-stream-v1`. A Mac that
    /// has not answered yet keeps the option (an older Mac's refusal then reads plainly).
    nonisolated static func streamsBrowser(_ capabilities: Set<String>?) -> Bool {
        capabilities.map { $0.contains("browser-stream-v1") || !$0.contains("removal-v1") } ?? true
    }

    public init(sync: WorkspaceSync, link: LinkController, acpmux: AcpmuxHub? = nil) {
        self.sync = sync
        self.link = link
        self.acpmux = acpmux
    }

    /// The Mac's acpmux client, once it exists (a Mac session makes both).
    func attach(acpmux: AcpmuxHub) {
        self.acpmux = acpmux
    }

    public func canCreate(on macID: String) -> Bool {
        link.target?.macID == macID && link.phase.isConnected && sync.daemon != nil && sync.macID == macID
    }

    /// Recent Directories are the folders of this Mac's workspaces (and the ones used here):
    /// the new workspace's terminal changes to it with `cd`, as the person would type, since
    /// the phone never sends a working directory (`cwd`) to the daemon.
    public func options(on macID: String) -> WorkspaceCreationOptions {
        // A plain tap opens at the Mac's default folder, as its New Workspace does. The
        // agent entry ("", the Mac's default agent) is New Agent Chat in a folder.
        WorkspaceCreationOptions(directories: true, agents: acpmux?.isReady == true ? [""] : [], browser: true,
                                 cloneFromGit: false, tapUsesLastDirectory: false)
    }

    /// The Mac's New Agent Chat over Home: a new workspace whose only tab is the
    /// chat, in `request.directory` (a folder of one of the Mac's workspaces, so
    /// acpmux's remote guard takes it). The chat starts first, so a folder that
    /// is not trusted yet leaves no empty workspace behind; then `create-workspace`
    /// (an empty workspace) and `new-conversation-tab {workspace}`, which makes its
    /// first pane. Nothing new on the daemon lane.
    func createChatWorkspace(_ request: NewWorkspaceRequest, start: AgentChatStart, placeholder: Workspace,
                             client: DaemonClient) async throws -> Workspace {
        let folders = Set((sync.tree?.directories ?? [:]).values)
        guard let cwd = Self.chatFolder(request.directory, known: folders) else {
            throw WorkspaceCreationError(Self.chatFolderRefusal, isForPerson: true)
        }
        guard !Self.isHomeOrAbove(cwd) else {
            throw WorkspaceCreationError("Agent chats start in a project folder, not the home folder. Pick a project folder.", isForPerson: true)
        }
        let (harness, session) = try await startAgentSession(start, cwd: cwd, macID: request.macID)
        do {
            let created = try WorkspaceSync.check(await client.request("create-workspace", params: ["name": placeholder.title]))
            let data = created["data"] as? [String: Any] ?? created
            guard let id = data["workspace"] as? Int, let key = data["key"] as? String else {
                throw WorkspaceCreationError("The Mac didn't say which workspace it created")
            }
            do {
                try WorkspaceSync.check(await client.request("new-conversation-tab", params: [
                    "workspace": id, "agent_session": ["harness": harness, "session": session],
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

    nonisolated static let chatFolderRefusal = "Agent chats start in a folder that's open on the Mac. Open a workspace there first (New Workspace › Open Folder…), then start the chat."

    /// The absolute folder for a chat workspace: `directory` as one of the Mac's
    /// workspace folders (`known`, absolute), matched as given or as the phone
    /// shows it (`~/…`). Nil for any other folder.
    nonisolated static func chatFolder(_ directory: String?, known: Set<String>) -> String? {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty else { return nil }
        if known.contains(directory) { return directory }
        return known.sorted().first { DaemonTree.abbreviated($0) == directory }
    }

    /// The line the new terminal runs for `directory` ("~/x" or "/x"): `cd` to it, then a
    /// clear screen, as a new workspace in that folder starts on the Mac. Nil for home.
    nonisolated static func changeDirectoryLine(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "~", trimmed != "~/" else { return nil }
        // The line is typed into a real shell: a character its line editor acts on (control
        // and format characters, DEL), a backslash (fish quotes) or `!` (csh history) could
        // edit the line or leave the quotes, so such a folder is never typed.
        guard WorkspaceFolderPath.isTypable(trimmed) else { return nil }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if trimmed.hasPrefix("~/") { return "cd ~/\(quoted(String(trimmed.dropFirst(2)))) && clear\n" }
        guard trimmed.hasPrefix("/") else { return nil }
        return "cd \(quoted(trimmed)) && clear\n"
    }

    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        guard canCreate(on: request.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        if case .agent(let harness) = request.start {
            return try await createChatWorkspace(request, start: AgentChatStart(harness: harness.isEmpty ? nil : harness),
                                                 placeholder: placeholder, client: client)
        }
        do {
            // One screen, one pane, one terminal at the daemon's default
            // directory; the new workspace becomes the active one.
            let reply = try WorkspaceSync.check(await client.request("new-workspace", params: ["name": placeholder.title]))
            guard let surface = (reply["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which workspace it created")
            }
            var opening = DaemonTree.tabID(surface: surface)
            if let directory = request.directory, let line = Self.changeDirectoryLine(directory) {
                _ = try? await client.request("send", params: ["surface": surface, "text": line])
            }
            if request.start == .browser {
                // No pane: the active pane, which is the new workspace's. If
                // the Mac has no browser runtime the workspace still stands,
                // and opens on its terminal.
                if let browser = try? WorkspaceSync.check(await client.request("new-browser-tab", params: ["url": "about:blank"])),
                   let id = (browser["data"] as? [String: Any])?["surface"] as? Int {
                    opening = DaemonTree.tabID(surface: id)
                }
            }
            let tree = try await sync.listNow()
            guard let created = tree.workspaces.first(where: { $0.tabs.contains { $0.id == opening } })
                ?? tree.workspaces.first(where: { $0.tabs.contains { $0.id == DaemonTree.tabID(surface: surface) } }) else {
                throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
            }
            return created
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// One tab of a phone's Duplicate Workspace.
    enum DuplicateStep: Hashable, Sendable {
        /// A new shell; `folder` is typed as `cd` when it can be (nil: the Mac's default).
        case terminal(folder: String?)
        case browser(url: String)
    }

    /// What Duplicate Workspace makes, as the Mac's `WorkspaceBlueprint`: each terminal tab
    /// again as a new shell in its folder, each web page again, in tab order. Agent chats and
    /// pages that are not http or https are left out (a phone never opens those itself).
    nonisolated static func duplicatePlan(_ workspace: Workspace, directories: [String: String]) -> [DuplicateStep] {
        workspace.tabs.compactMap { tab in
            switch tab.kind {
            case .terminal:
                return .terminal(folder: directories[tab.id] ?? tab.subtitle)
            case .browser:
                guard let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return .browser(url: url.absoluteString)
            case .agent, .simulator:
                return nil
            }
        }
    }

    /// The Mac's Duplicate Workspace (`workspace.duplicate`), from lines a phone already
    /// sends: `new-workspace {name}` (one shell), then in its pane `new-tab {pane}` per
    /// terminal and `new-browser-tab {url, pane}` per page, and each shell gets
    /// `cd '<folder>' && clear` typed (`changeDirectoryLine`), as New Workspace in a folder.
    /// The daemon never takes a program or folder from the phone. Unlike the Mac, every tab
    /// goes in one pane (the phone does not copy splits), and color and icon stay.
    public func duplicate(_ workspace: Workspace) async throws -> Workspace {
        guard canManage(on: workspace.macID), let client = sync.daemon, let tree = sync.tree else {
            throw WorkspaceCreationError("Not connected")
        }
        guard !workspace.isHome else { throw WorkspaceCreationError("Home has no duplicate.", isForPerson: true) }
        let plan = Self.duplicatePlan(workspace, directories: tree.directories)
        do {
            func surface(_ reply: Data) throws -> Int {
                guard let id = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                    throw WorkspaceCreationError("The Mac didn't say which tab it opened")
                }
                return id
            }
            let first = try surface(await client.request("new-workspace", params: ["name": workspace.title]))
            let listed = try await sync.listNow()
            let firstID = DaemonTree.tabID(surface: first)
            guard let pane = listed.tabPlaces[firstID]?.pane,
                  let createdID = listed.workspaces.first(where: { $0.tabs.contains { $0.id == firstID } })?.id else {
                // Its first tab is all there is of it: close it, so no empty copy stays.
                _ = try? await client.request("close-surface", params: ["surface": first])
                throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
            }
            // Pages only on a Mac that streams browser tabs; one that fails is left out (as
            // New Browser Tab is optional elsewhere), never the terminals after it.
            let pages = Self.streamsBrowser(capabilities(workspace.macID))
            var firstUsed = false
            do {
                for step in plan {
                    switch step {
                    case .terminal(let folder):
                        let shell: Int
                        if firstUsed {
                            shell = try surface(await client.request("new-tab", params: ["pane": pane]))
                        } else {
                            shell = first
                            firstUsed = true
                        }
                        if let folder, let line = Self.changeDirectoryLine(folder) {
                            _ = try? await client.request("send", params: ["surface": shell, "text": line])
                        }
                    case .browser(let url):
                        guard pages else { continue }
                        _ = try? await client.request("new-browser-tab", params: ["url": url, "pane": pane])
                    }
                }
            } catch {
                // A half-made copy is never left behind.
                _ = try? await client.request("close-workspace", params: ["key": createdID])
                throw error
            }
            // Only pages: the first shell goes, as the Mac's builder closes its initial tab.
            if !firstUsed, !plan.isEmpty {
                _ = try? await client.request("close-surface", params: ["surface": first])
            }
            let tree = try await sync.listNow()
            guard let created = tree.workspaces.first(where: { $0.id == createdID }) else {
                throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
            }
            return created
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// The daemon lane allows `rename-workspace` and `close-workspace` on
    /// the linked Mac.
    public func canManage(on macID: String) -> Bool { canCreate(on: macID) }

    public func rename(_ workspace: Workspace, to title: String) async throws {
        try await send("rename-workspace", workspace, name: title)
    }

    public func close(_ workspace: Workspace) async throws {
        try await send("close-workspace", workspace, name: nil)
    }

    // MARK: Tabs

    /// Terminal and browser tabs need only the daemon lane; an agent tab also
    /// needs acpmux ready to start its session. One model-agnostic agent entry,
    /// as the Mac's New Agent Chat: the Mac's default agent, or one chosen from
    /// its catalog (`agentCatalog`).
    public func tabKinds(on macID: String) -> [NewTabKind] {
        guard canManage(on: macID) else { return [] }
        let agents: [NewTabKind] = acpmux?.isReady == true ? [.agentChat] : []
        return agents + [.terminal] + (Self.streamsBrowser(capabilities(macID)) ? [.browser] : [])
    }

    /// What the phone shows but can't open yet, with why: an older Mac that does not
    /// stream browser tabs, or agents whose acpmux link is not up yet.
    public func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)] {
        guard canManage(on: macID) else { return [] }
        var out: [(kind: NewTabKind, reason: String)] = []
        if acpmux?.isReady != true {
            out.append((.agentChat, "Agents on this Mac aren't connected yet. Try again in a moment."))
        }
        if !Self.streamsBrowser(capabilities(macID)) {
            out.append((.browser, Self.browserUpdateReason))
        }
        return out
    }

    /// An older Mac (its hostd does not say `browser-stream-v1`).
    public static let browserUpdateReason = "Update cmux on your Mac to open browser tabs from your phone."

    /// The Mac's agents now: `_acpmux/harnesses`, and `_acpmux/models` when it answers.
    public func agentCatalog(on macID: String) async throws -> AgentCatalog {
        try await agentCatalog(on: macID, models: true)
    }

    /// `models: false` for a start that names no model: the harness list alone decides it.
    func agentCatalog(on macID: String, models withModels: Bool) async throws -> AgentCatalog {
        guard canManage(on: macID), let acpmux, acpmux.isReady else {
            throw WorkspaceCreationError("Agents on this Mac aren't connected yet. Try again in a moment.", isForPerson: true)
        }
        let harnesses: JSONValue
        do {
            harnesses = try await acpmux.request("_acpmux/harnesses", .object([:]), timeout: .seconds(15))
        } catch {
            throw WorkspaceCreationError(AcpmuxSessionSource.message(error))
        }
        let models = withModels ? try? await acpmux.request("_acpmux/models", .object([:]), timeout: .seconds(10)) : nil
        return AgentCatalog(harnesses: harnesses, models: models)
    }

    /// Opens the tab on the Mac in the workspace's active pane, then waits
    /// until the Mac lists it, so the phone shows only what the Mac has:
    /// - terminal: `new-tab` (the Mac's default shell; no program, folder or env from the phone);
    /// - browser: `new-browser-tab about:blank`;
    /// - agent: acpmux `session/new` in the workspace's folder (asking
    ///   policy, no MCP servers; acpmux's remote guard checks the folder),
    ///   then `new-conversation-tab` showing that session (cmux-mobile-host records
    ///   it as this Mac's own chat).
    public func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        guard let pane = sync.tree?.panes[workspace.id] else {
            throw WorkspaceCreationError("The Mac hasn't listed this workspace's panes yet")
        }
        do {
            let reply: Data
            switch kind {
            case .terminal:
                reply = try await client.request("new-tab", params: ["pane": pane])
            case .browser:
                reply = try await client.request("new-browser-tab", params: ["url": "about:blank", "pane": pane])
            case .agent(let start):
                let (harness, session) = try await startAgentSession(start, in: workspace)
                reply = try await client.request("new-conversation-tab", params: [
                    "pane": pane,
                    "agent_session": ["harness": harness, "session": session],
                ])
            }
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            let id = DaemonTree.tabID(surface: surface)
            let tree = try await sync.listNow()
            guard let tab = tree.workspaces.first(where: { $0.id == workspace.id })?.tabs.first(where: { $0.id == id })
                ?? tree.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw WorkspaceCreationError("The new tab didn't appear on the Mac")
            }
            return tab
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// The new chat's acpmux session, in the folder of the workspace's
    /// terminal on the Mac: the harness the start names, else the Mac's default
    /// agent (or the first one a phone may start); then its model, when one was
    /// chosen, with `session/set_model` as the Mac's New Tab page does.
    private func startAgentSession(_ start: AgentChatStart, in workspace: Workspace) async throws -> (harness: String, session: String) {
        guard let acpmux, acpmux.isReady else { throw WorkspaceCreationError("Agents on this Mac aren't connected yet. Try again in a moment.", isForPerson: true) }
        let directories = sync.tree?.directories ?? [:]
        guard let cwd = workspace.tabs.lazy.compactMap({ directories[$0.id] }).first else {
            throw WorkspaceCreationError("This workspace has no folder on the Mac yet. Open a terminal tab first.", isForPerson: true)
        }
        guard !Self.isHomeOrAbove(cwd) else {
            throw WorkspaceCreationError("Agent chats start in a project folder. Open this workspace in one (New Workspace › Open Folder… or Recent Directories) or cd into one in its terminal.",
                                         isForPerson: true)
        }
        return try await startAgentSession(start, cwd: cwd, macID: workspace.macID)
    }

    /// The new chat's acpmux session in `cwd` (an absolute folder on the Mac).
    func startAgentSession(_ start: AgentChatStart, cwd: String, macID: String) async throws -> (harness: String, session: String) {
        guard let acpmux, acpmux.isReady else { throw WorkspaceCreationError("Agents on this Mac aren't connected yet. Try again in a moment.", isForPerson: true) }
        let catalog = try await agentCatalog(on: macID, models: start.model != nil)
        guard let (choice, model) = catalog.resolve(start, folder: cwd) else {
            if let id = start.harness, let reason = catalog.harness(id)?.unavailableReason {
                throw WorkspaceCreationError(reason, isForPerson: true)
            }
            throw WorkspaceCreationError(catalog.unavailableReason ?? "No agent on this Mac can start a chat from your iPhone.", isForPerson: true)
        }
        let reply: JSONValue
        do {
            reply = try await acpmux.request("session/new", .object([
                "cwd": .string(cwd), "mcpServers": .array([]),
                "_meta": .object(["acpmux": .object(["harness": .string(choice.id), "policy": .string("ask")])]),
            ]), timeout: .seconds(90))
        } catch let error as AcpmuxConnection.RPCError where error.reason == "trust.pending" || error.reason == "trust.untrusted" {
            // acpmux asks the person to trust a new folder, and only on the Mac (a phone may
            // not answer: `acp.trust.set` is refused remotely). Claude's own trust answer counts too.
            let folder = (cwd as NSString).lastPathComponent
            throw WorkspaceCreationError(error.reason == "trust.untrusted"
                ? "\(folder) is marked Don't Trust on this Mac. Trust it in cmux on the Mac to start agent chats there."
                : Self.trustSteps(folder: folder),
                isForPerson: true)
        } catch let error as AcpmuxConnection.RPCError where error.reason == "route.unavailable" {
            throw WorkspaceCreationError(Self.routeUnavailable(error.message), isForPerson: true)
        } catch {
            throw WorkspaceCreationError(AcpmuxSessionSource.message(error))
        }
        guard let session = reply["sessionId"]?.stringValue, !session.isEmpty else {
            throw WorkspaceCreationError("The Mac didn't start the chat")
        }
        if let model {
            // The chat stands on the harness's default model if the Mac refuses this one.
            do {
                _ = try await acpmux.request("session/set_model", .object(["sessionId": .string(session), "modelId": .string(model)]),
                                             timeout: .seconds(20))
            } catch {
                creationLog.error("set_model \(model, privacy: .public) refused: \(AcpmuxSessionSource.message(error), privacy: .public)")
            }
        }
        return (choice.id, session)
    }

    /// acpmux could not reach the model service the agent's route needs (`route.unavailable`):
    /// the cmux model service on the Mac (its local router) is not running or not signed in.
    /// Said plainly, without the Mac's command line.
    nonisolated static func routeUnavailable(_ detail: String) -> String {
        if detail.contains("not connected") {
            return "cmux's model service isn't signed in on the Mac. Open cmux on the Mac, then try again, or choose another agent."
        }
        return "cmux's model service isn't running on the Mac. Quit and reopen cmux on the Mac, then try again, or choose another agent."
    }

    /// What to do when acpmux waits for the person to trust a new folder: it
    /// asks only on the Mac (a phone may not answer `acp.trust.set`), and
    /// Claude's own trust answer counts too.
    nonisolated static func trustSteps(folder: String) -> String {
        "Claude hasn't been trusted in \(folder) yet. Either: 1. On the Mac, open this workspace in cmux and choose Trust when it asks. "
            + "Or 2. Here, open this workspace's terminal, type claude, press Return, choose \u{201C}Yes, I trust this folder\u{201D}, then type /exit. "
            + "Then start the chat again."
    }

    /// `/`, `/Users`, or a home folder (`/Users/<name>`, `/var/root`): acpmux never starts a
    /// remote chat there (`web_roots` drops the home folder and everything above it).
    nonisolated static func isHomeOrAbove(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.isEmpty { return true }
        if parts == ["var", "root"] || parts == ["var"] { return true }
        return parts.first == "Users" && parts.count <= 2 && parts.last != "Shared"
    }

    /// `close-surface` on the Mac, then `close-terminal` for the tab's own
    /// terminal, then a fresh list. `close-surface` only detaches a terminal
    /// (the daemon reaps a tab-less one after its grace period, so the Mac
    /// listed it running 50 s after the close, V5-5); the phone has no undo
    /// and its close question says the program stops, so the terminal ends
    /// at once (T-TABS-08), unless another tab still shows it. A refused
    /// `close-terminal` leaves the reap to the daemon: the tab is closed.
    public func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        guard let surface = sync.tree?.surfaces[tab.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        let terminals = sync.tree?.terminalsEndedByClosing([tab.id]) ?? []
        do {
            try WorkspaceSync.check(await client.request("close-surface", params: ["surface": surface]))
            await end(terminals, on: client)
            _ = try? await sync.listNow()
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// `close-terminal` for each terminal a phone close ended (`terminalsEndedByClosing`),
    /// after its tabs closed. A refusal leaves the reap to the daemon: the tabs are closed.
    private func end(_ terminals: [DaemonTree.TerminalRef], on client: DaemonClient) async {
        for terminal in terminals {
            do {
                try WorkspaceSync.check(await client.request("close-terminal", params: Self.closeParams(terminal)))
            } catch {
                creationLog.error("close-terminal \(terminal.id, privacy: .public) after the tab closed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated static func closeParams(_ terminal: DaemonTree.TerminalRef) -> sending [String: Any] {
        var params: [String: Any] = ["terminal_id": terminal.id]
        if let incarnation = terminal.incarnation { params["terminal_incarnation"] = incarnation }
        return params
    }

    /// The foreground programs in `tabs`' terminals (`process-info`, one bounded read per
    /// terminal, concurrent, 1 s each as on the Mac). No link, an unlisted tab, a refusal or
    /// a late reply count as idle: the close never waits on a quiet Mac.
    public func runningPrograms(of tabs: [WorkspaceTab], in workspace: Workspace) async -> [String] {
        guard canManage(on: workspace.macID), let client = sync.daemon else { return [] }
        let surfaces = tabs.filter { $0.kind == .terminal }.compactMap { sync.tree?.surfaces[$0.id] }
        guard !surfaces.isEmpty else { return [] }
        let replies = await withTaskGroup(of: (Int, Result<Data, any Error>).self) { group in
            for surface in surfaces {
                group.addTask {
                    // One return of a local: swiftlang/swift#92698 drops a tuple's first
                    // element at -O when an awaiting do and its catch each return one.
                    let reply: Result<Data, any Error>
                    do {
                        reply = .success(try await client.request("process-info", params: ["surface": surface],
                                                                  deadline: Self.processInfoDeadline))
                    } catch {
                        reply = .failure(error)
                    }
                    return (surface, reply)
                }
            }
            var replies: [(Int, Result<Data, any Error>)] = []
            for await reply in group { replies.append(reply) }
            return replies
        }
        var programs: [String] = []
        for (surface, reply) in replies {
            do {
                if let program = TerminalProcessInfo(reply: try WorkspaceSync.check(try reply.get())).runningProgram {
                    programs.append(program)
                }
            } catch {
                creationLog.error("process-info \(surface) before a close: \(String(describing: error), privacy: .public)")
            }
        }
        return Set(programs).sorted()
    }

    /// How long a close waits for one terminal's `process-info` (the Mac's 1 s).
    nonisolated static let processInfoDeadline: Duration = .seconds(1)

    // MARK: Tab edits

    public func canEditTabs(on macID: String) -> Bool { canManage(on: macID) }

    /// `rename-surface {surface, name}` (the Mac's Rename Tab…), then a fresh list.
    public func renameTab(_ tab: WorkspaceTab, in workspace: Workspace, to title: String) async throws {
        let (client, surface) = try target(tab, in: workspace)
        try await run(client, "rename-surface", ["surface": surface, "name": title])
    }

    /// The Mac's Duplicate Tab: a terminal is a new terminal in the tab's pane (the Mac
    /// picks the folder, as for any new terminal from a phone); a browser tab is the same
    /// web page in a new browser tab there; an agent chat is a second tab of the same chat.
    public func duplicateTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        let (client, _) = try target(tab, in: workspace)
        guard let place = sync.tree?.tabPlaces[tab.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        let reply: Data
        do {
            switch tab.kind {
            case .terminal:
                reply = try await client.request("new-tab", params: ["pane": place.pane])
            case .browser:
                let url = tab.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil }
                reply = try await client.request("new-browser-tab", params: ["url": url ?? "about:blank", "pane": place.pane])
            case .simulator:
                throw WorkspaceCreationError("Duplicate phone tabs on your Mac.", isForPerson: true)
            case .agent:
                // The Mac's Duplicate Tab on a chat opens a second tab of the same chat
                // (`PaneController.duplicateAgentTab`), never a copy of the conversation.
                guard let binding = sync.tree?.agentTabs[tab.id], let session = binding.session else {
                    throw WorkspaceCreationError("This chat hasn't started yet.", isForPerson: true)
                }
                reply = try await client.request("new-conversation-tab", params: [
                    "pane": place.pane,
                    "agent_session": ["harness": binding.harness ?? "claude", "session": session],
                ])
            }
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            let id = DaemonTree.tabID(surface: surface)
            let tree = try await sync.listNow()
            guard let copy = tree.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw WorkspaceCreationError("The new tab didn't appear on the Mac")
            }
            return copy
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// A web link tapped in a terminal (the Mac's Cmd-click, `TerminalHostDelegate.openWeb`):
    /// `new-browser-tab {url, pane}` in the terminal's own pane, so the page opens beside it in
    /// the same workspace. Only `http` and `https` (the mobile host refuses any other scheme).
    public func openLink(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw WorkspaceCreationError("Only web links open in a browser tab.", isForPerson: true)
        }
        let (client, _) = try target(tab, in: workspace)
        guard let place = sync.tree?.tabPlaces[tab.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        do {
            let reply = try await client.request("new-browser-tab", params: ["url": url.absoluteString, "pane": place.pane])
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            let id = DaemonTree.tabID(surface: surface)
            let tree = try await sync.listNow()
            guard let opened = tree.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw WorkspaceCreationError("The new tab didn't appear on the Mac")
            }
            return opened
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// `move-tab {surface, pane, index}`: to the target's pane and place.
    /// Within the tab's own pane only: a drag onto a tab of another pane would move it into
    /// that pane (and could close a split), a layout change, not a reorder.
    public func moveTab(_ tab: WorkspaceTab, to target: WorkspaceTab, in workspace: Workspace) async throws {
        let (client, surface) = try self.target(tab, in: workspace)
        guard let from = sync.tree?.tabPlaces[tab.id], let to = sync.tree?.tabPlaces[target.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        guard let index = Self.moveIndex(from: from, to: to) else {
            throw WorkspaceCreationError("These tabs are in different panes on the Mac. Move tabs between panes there.",
                                         isForPerson: true)
        }
        try await run(client, "move-tab", ["surface": surface, "pane": to.pane, "index": index])
    }

    /// `move-tab`'s `index` is an insertion point in the pane's current list (the daemon uses
    /// `index - 1` past the tab's own place), so a forward move to the target's place sends
    /// one more. Nil across panes.
    nonisolated static func moveIndex(from: DaemonTree.TabPlace, to: DaemonTree.TabPlace) -> Int? {
        guard from.pane == to.pane else { return nil }
        return to.index > from.index ? to.index + 1 : to.index
    }

    // MARK: Move to another workspace, pins, groups

    /// The Mac's Move Tab to Workspace… (`move-tab-to-workspace {surface, workspace}`: the
    /// destination's active pane) and Move Tab to New Workspace (`move-tab-to-new-workspace`,
    /// named as the Mac names it). Nothing restarts: the tab keeps its terminal, page or chat.
    public func moveTab(_ tab: WorkspaceTab, from workspace: Workspace, toWorkspace destination: Workspace?) async throws -> Workspace? {
        let (client, surface) = try target(tab, in: workspace)
        var number: Int?
        var name: String?
        if let destination {
            guard destination.macID == workspace.macID else {
                throw WorkspaceCreationError("Workspaces on different Macs can't share tabs.", isForPerson: true)
            }
            guard destination.id != workspace.id else { return workspace }
            guard let id = sync.tree?.workspaceNumbers[destination.id] else {
                throw WorkspaceCreationError("The Mac doesn't list that workspace")
            }
            number = id
        } else {
            name = Self.newWorkspaceName(for: tab, in: workspace)
        }
        let command = number == nil ? "move-tab-to-new-workspace" : "move-tab-to-workspace"
        do {
            do {
                try WorkspaceSync.check(await client.request(command, params: Self.moveParams(surface: surface, workspace: number, name: name)))
            } catch let error as DaemonReplyError where name != nil && error.message.lowercased().contains("name") {
                // A daemon without `tab-workspace-name-v1`: its default name, as the Mac's older path.
                try WorkspaceSync.check(await client.request(command, params: Self.moveParams(surface: surface, workspace: number, name: nil)))
            }
            let tree = try await sync.listNow()
            return tree.workspaces.first { $0.tabs.contains { $0.id == tab.id } }
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    nonisolated static func moveParams(surface: Int, workspace: Int?, name: String?) -> sending [String: Any] {
        var params: [String: Any] = ["surface": surface]
        if let workspace { params["workspace"] = workspace }
        if let name { params["name"] = name }
        return params
    }

    /// The Mac's rule for a workspace made from a tab (`NewWorkspaceName`): the last tab of a
    /// workspace keeps the workspace's own name; else the tab's name, a browser's page title or
    /// host, a terminal's title unless it is a bare shell, then its folder. Nil: the Mac's default.
    nonisolated static func newWorkspaceName(for tab: WorkspaceTab, in workspace: Workspace) -> String? {
        func clean(_ raw: String?) -> String? {
            let line = (raw ?? "").split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return line.isEmpty ? nil : String(line.prefix(80))
        }
        if workspace.tabs.count == 1, let title = clean(workspace.title), !isDefaultWorkspaceName(title) { return title }
        switch tab.kind {
        case .browser:
            if let title = clean(tab.title), title != tab.url?.absoluteString, title != "Browser" { return title }
            return clean(tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 })
        case .terminal:
            let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "dash", "ksh", "tcsh", "pwsh", "login", "Terminal"]
            if let title = clean(tab.title), !shells.contains(title.hasPrefix("-") ? String(title.dropFirst()) : title) { return title }
            let folder = tab.subtitle.map { ($0 as NSString).lastPathComponent }
            return clean(folder == "/" || folder == "~" ? nil : folder)
        case .agent, .simulator:
            return clean(tab.title)
        }
    }

    /// `workspace-N`, the daemon's default name.
    nonisolated static func isDefaultWorkspaceName(_ name: String) -> Bool {
        guard name.hasPrefix("workspace-") else { return false }
        let number = name.dropFirst("workspace-".count)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Pin Tab / Unpin Tab (`set-tab-pinned`): pinned tabs sort first in their pane.
    /// The Mac's Restart Shell Here (`tab.restart`): the tab names only its surface; the
    /// Mac starts the tab's own shell again under the same terminal id.
    public func restartShell(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        let (client, surface) = try target(tab, in: workspace)
        try await run(client, "restart-tab", ["surface": surface])
    }

    public func setTabPinned(_ tab: WorkspaceTab, in workspace: Workspace, pinned: Bool) async throws {
        let (client, surface) = try target(tab, in: workspace)
        try await run(client, "set-tab-pinned", ["surface": surface, "pinned": pinned])
    }

    /// The Mac's tab group actions (`TabGroupHandlers`), on the tab's own group.
    public func editTabGroup(_ edit: TabGroupEdit, tab: WorkspaceTab, in workspace: Workspace) async throws {
        let (client, surface) = try target(tab, in: workspace)
        switch edit {
        case .create:
            guard !tab.isPinned else { throw WorkspaceCreationError(Self.pinnedCannotGroup, isForPerson: true) }
            let pane = sync.tree?.tabPlaces[tab.id]?.pane
            let used = Set(workspace.tabs.filter { pane != nil && sync.tree?.tabPlaces[$0.id]?.pane == pane }.compactMap { $0.group?.color })
            try await run(client, "create-tab-group", ["surfaces": [surface], "color": WorkspaceTab.TabGroupRef.nextColor(used: used)])
        case .add(let group):
            guard !tab.isPinned else { throw WorkspaceCreationError(Self.pinnedCannotGroup, isForPerson: true) }
            try await run(client, "add-tabs-to-tab-group", ["group": group, "surfaces": [surface]])
        case .remove:
            try await run(client, "remove-tabs-from-tab-group", ["surfaces": [surface]])
        case .rename(let name):
            try await run(client, "update-tab-group", ["group": try group(of: tab), "name": name])
        case .ungroup:
            try await run(client, "ungroup-tab-group", ["group": try group(of: tab)])
        case .close:
            // The phone has no undo: each member's terminal ends, as a tab close ends it (A2).
            let id = try group(of: tab)
            let members = workspace.tabs.filter { $0.group?.id == id }.map(\.id)
            let terminals = sync.tree?.terminalsEndedByClosing(members) ?? []
            do {
                try WorkspaceSync.check(await client.request("close-tab-group", params: ["group": id]))
                await end(terminals, on: client)
                _ = try? await sync.listNow()
            } catch let error as DaemonReplyError {
                throw WorkspaceCreationError(error.message)
            }
        case .save:
            try await run(client, "save-tab-group", ["group": try group(of: tab)])
        case .unsave:
            try await run(client, "unsave-tab-group", ["group": try group(of: tab)])
        }
    }

    // MARK: Saved tab groups (Reopen / Delete Saved Tab Group…)

    /// The Mac's saved groups (`list-saved-tab-groups`), each marked open when one of its live
    /// groups (`list-tab-groups`) links to it, as the Mac's `openGroup`.
    public func savedTabGroups(on macID: String) async throws -> [SavedTabGroup] {
        guard canManage(on: macID), let client = sync.daemon else { throw WorkspaceCreationError("Not connected") }
        do {
            let saved = try WorkspaceSync.check(await client.request("list-saved-tab-groups"))
            let open = try WorkspaceSync.check(await client.request("list-tab-groups"))
            return Self.savedTabGroups(saved: saved, open: open)
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// Parses `list-saved-tab-groups` and `list-tab-groups` replies (`{"ok":true,"data":{...}}`
    /// or the bare data object).
    nonisolated static func savedTabGroups(saved: [String: Any], open: [String: Any]) -> [SavedTabGroup] {
        func data(_ reply: [String: Any]) -> [String: Any] { reply["data"] as? [String: Any] ?? reply }
        let linked = Set((data(open)["groups"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["saved_id"] as? String })
        return (data(saved)["saved_groups"] as? [Any] ?? []).compactMap { value -> SavedTabGroup? in
            guard let record = value as? [String: Any], let id = record["id"] as? String, !id.isEmpty else { return nil }
            let kinds = (record["members"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["kind"] as? String }
            return SavedTabGroup(id: id, name: record["name"] as? String ?? "", color: record["color"] as? String ?? "grey",
                                 terminals: kinds.filter { $0 == "terminal" }.count,
                                 browsers: kinds.filter { $0 == "browser" }.count, isOpen: linked.contains(id))
        }
    }

    /// The Mac's `tabGroup.reopenSaved`: the saved id and the pane only. The Mac reopens each
    /// terminal from its own record (a new login shell in the saved folder, or the same
    /// terminal while it still runs); the phone names no program, folder or environment.
    public func reopenSavedTabGroup(_ saved: SavedTabGroup, besides tab: WorkspaceTab, in workspace: Workspace) async throws {
        let (client, _) = try target(tab, in: workspace)
        guard !saved.isOpen else { throw WorkspaceCreationError(SavedTabGroupAction.alreadyOpen, isForPerson: true) }
        guard let pane = sync.tree?.tabPlaces[tab.id]?.pane ?? sync.tree?.panes[workspace.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        try await run(client, "reopen-saved-tab-group", ["saved": saved.id, "pane": pane])
    }

    /// The Mac's `tabGroup.deleteSaved`: the record goes; an open group stays, unpinned.
    public func deleteSavedTabGroup(_ saved: SavedTabGroup, on macID: String) async throws {
        guard canManage(on: macID), let client = sync.daemon else { throw WorkspaceCreationError("Not connected") }
        try await run(client, "delete-saved-tab-group", ["saved": saved.id])
    }

    /// The Mac's refusal (`RefusalStrings.pinnedCannotGroup`), as a sentence.
    nonisolated static let pinnedCannotGroup = "Pinned tabs cannot be grouped."


    private func group(of tab: WorkspaceTab) throws -> String {
        guard let group = tab.group?.id else { throw WorkspaceCreationError("This tab isn't in a group.", isForPerson: true) }
        return group
    }

    // MARK: Agent chat menu (Fork, Archive)

    /// The chat menu's Fork: acpmux `session/fork` (the whole chat), then a tab of the copy in
    /// the chat's pane, as the Mac opens a fork in a tab of its own. acpmux refuses a fork of a
    /// Claude chat the Mac started (D13); its reason is shown as the Mac words it.
    public func forkAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        let (client, _) = try target(tab, in: workspace)
        guard let acpmux, acpmux.isReady else {
            throw WorkspaceCreationError("Agents on this Mac aren't connected yet. Try again in a moment.", isForPerson: true)
        }
        guard let binding = sync.tree?.agentTabs[tab.id], let session = binding.session,
              let place = sync.tree?.tabPlaces[tab.id] else {
            throw WorkspaceCreationError("This chat hasn't started yet.", isForPerson: true)
        }
        let forked: String
        do {
            let reply = try await acpmux.request("session/fork", .object(["sessionId": .string(session)]), timeout: .seconds(60))
            guard let id = reply["sessionId"]?.stringValue, !id.isEmpty else { throw WorkspaceCreationError("The Mac didn't fork the chat") }
            forked = id
        } catch let error as AcpmuxConnection.RPCError {
            throw WorkspaceCreationError(error.message, isForPerson: true)
        }
        do {
            let reply = try await client.request("new-conversation-tab", params: [
                "pane": place.pane, "agent_session": ["harness": binding.harness ?? "claude", "session": forked],
            ])
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            let id = DaemonTree.tabID(surface: surface)
            let tree = try await sync.listNow()
            guard let copy = tree.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw WorkspaceCreationError("The new tab didn't appear on the Mac")
            }
            return copy
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// The chat menu's Archive: acpmux `_acpmux/archive {archived: true}`, then the tab closes,
    /// as the Mac's pane asks its app to close it.
    public func archiveAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        let (client, surface) = try target(tab, in: workspace)
        guard let acpmux, acpmux.isReady else {
            throw WorkspaceCreationError("Agents on this Mac aren't connected yet. Try again in a moment.", isForPerson: true)
        }
        guard let session = sync.tree?.agentTabs[tab.id]?.session else {
            throw WorkspaceCreationError("This chat hasn't started yet.", isForPerson: true)
        }
        do {
            _ = try await acpmux.request("_acpmux/archive", .object(["sessionId": .string(session), "archived": .bool(true)]),
                                         timeout: .seconds(20))
        } catch let error as AcpmuxConnection.RPCError {
            throw WorkspaceCreationError(error.message, isForPerson: true)
        }
        try await run(client, "close-surface", ["surface": surface])
    }

    private func target(_ tab: WorkspaceTab, in workspace: Workspace) throws -> (DaemonClient, Int) {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        guard let surface = sync.tree?.surfaces[tab.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        return (client, surface)
    }

    private func run(_ client: DaemonClient, _ command: String, _ params: sending [String: Any]) async throws {
        do {
            try WorkspaceSync.check(await client.request(command, params: params))
            _ = try? await sync.listNow()
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// Workspaces are addressed by key; a tree without keys gave "w<id>".
    private func send(_ cmd: String, _ workspace: Workspace, name: String?) async throws {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        var params: [String: Any] = [:]
        if let name { params["name"] = name }
        if workspace.id.hasPrefix("w"), let id = Int(workspace.id.dropFirst()) {
            params["workspace"] = id
        } else {
            params["key"] = workspace.id
        }
        do {
            try WorkspaceSync.check(await client.request(cmd, params: params))
            _ = try? await sync.listNow()
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }
}
