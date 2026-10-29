import CmuxNextCompat
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

typealias TransferJSONValue = CmuxNextSettings.JSONValue

/// A live tab that another local cmux build can hand to this App.
nonisolated struct SessionTransferItem: Sendable, Equatable, Identifiable {
    let sourceSurface: String
    let workspace: String
    let kind: Kind
    let title: String
    let cwd: String?
    /// The host portion of an SSH command, when the source exposes one.
    let sshTarget: String?
    /// A source terminal's original launch command, when available (classic peers).
    let command: String?
    let agentHarness: String?
    let agentSessionID: String?
    /// A `chat` (a cmux-next agent chat, `agentSessionID` its acpmux session): the source build's
    /// acpmux socket and home, which `acpmux transfer` moves it from.
    var acpmuxSocket: String?
    var acpmuxHome: String?

    /// `agent` resumes a harness's own session id; `chat` moves an acpmux chat with its history,
    /// queue and draft (a build that predates it skips the record).
    nonisolated enum Kind: String, Sendable { case terminal, agent, chat }
    var id: String { sourceSurface }

    var json: TransferJSONValue {
        [
            "surface": .string(sourceSurface),
            "workspace": .string(workspace),
            "kind": .string(kind.rawValue),
            "title": .string(title),
            "cwd": .optional(cwd),
            "ssh_target": .optional(sshTarget),
            "command": .optional(command),
            "agent": .optional(agentHarness),
            "agent_session": .optional(agentSessionID),
            "acpmux_socket": .optional(acpmuxSocket),
            "acpmux_home": .optional(acpmuxHome),
        ]
    }

    init(sourceSurface: String, workspace: String, kind: Kind, title: String, cwd: String?, sshTarget: String?,
         command: String?, agentHarness: String?, agentSessionID: String?) {
        self.sourceSurface = sourceSurface
        self.workspace = workspace
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.sshTarget = sshTarget
        self.command = command
        self.agentHarness = agentHarness
        self.agentSessionID = agentSessionID
    }

    init?(json: TransferJSONValue, defaultWorkspace: String = "") {
        guard let object = json.objectValue,
              let sourceSurface = object["surface"]?.stringValue ?? object["id"]?.stringValue,
              let kind = object["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.sourceSurface = sourceSurface
        workspace = object["workspace"]?.stringValue ?? object["workspace_id"]?.stringValue ?? defaultWorkspace
        self.kind = kind
        title = object["title"]?.stringValue ?? object["name"]?.stringValue ?? ""
        cwd = object["cwd"]?.stringValue
        sshTarget = object["ssh_target"]?.stringValue
        command = object["command"]?.stringValue
        agentHarness = object["agent"]?.stringValue
        agentSessionID = object["agent_session"]?.stringValue
        acpmuxSocket = object["acpmux_socket"]?.stringValue
        acpmuxHome = object["acpmux_home"]?.stringValue
    }
}

nonisolated struct SessionTransferPeer: Sendable {
    let path: String
    let app: String
    let build: String
    let tag: String?
    let pid: Int32
    let items: [SessionTransferItem]
}

/// Discovers live sibling builds and performs an acknowledge-then-close move.
/// The destination creates every item first; a source is only asked to close
/// after the corresponding destination operation succeeds. Reached only over
/// the control socket (`session.transfer.peers` / `session.transfer.pull`),
/// for scripts and agents; there is no migration UI.
@MainActor
final class SessionTransferService {
    private(set) weak var services: AppServices?
    /// The app's main-thread scheduler: the one main read of the nonisolated discovery, and the tab waits.
    private nonisolated let mainWork: MainWorkScheduler

    init(services: AppServices) {
        self.services = services
        mainWork = services.mainWork
    }

    /// How long a moved agent waits for its conversation tab (the old poll's 20 × 250 ms).
    static let conversationTabLimit: Duration = .seconds(5)

    /// Moves the selected sessions (all of them when `ids` is empty) from the one
    /// peer named by `source` (its socket path or tag). A terminal's move opens a new
    /// shell in the same folder and ends the source's process; a chat's moves the chat
    /// itself (``moveChat(_:interrupt:cwd:)``), refused while it runs a turn unless `interrupt`, and
    /// into folder `cwd` here when given (a chat whose folder is not on this machine).
    /// One item's failure never stops the others; each is reported.
    func pull(source: String, ids: Set<String> = [], interrupt: Bool = false, cwd: String? = nil) async throws -> TransferJSONValue {
        let peers = try await discover(only: source)
        let selected = peers.flatMap { peer -> [(SessionTransferPeer, SessionTransferItem)] in
            guard source == peer.path || source == peer.tag else { return [] }
            return peer.items.filter { ids.isEmpty || ids.contains($0.id) }.map { (peer, $0) }
        }
        guard !selected.isEmpty else { throw Failure.noSessions }
        var moved: [TransferJSONValue] = []
        var failed: [TransferJSONValue] = []
        for (peer, item) in selected {
            // A pull past its deadline (the control router cancels it) moves nothing more.
            try Task.checkCancellation()
            do {
                try await move(item, from: peer, interrupt: interrupt, cwd: cwd)
                moved.append(item.json)
            } catch {
                var entry: [String: TransferJSONValue] = ["surface": .string(item.id), "source": .string(peer.path), "error": .string(Self.message(for: error))]
                // Pulled again with `cwd`, it moves into that folder instead.
                if case Failure.chatFolderMissing(let folder) = error { entry["missing_folder"] = .string(folder) }
                failed.append(.object(entry))
            }
        }
        return ["moved": .array(moved), "failed": .array(failed)]
    }

    func complete(surfaces: [String]) async throws {
        guard let services, let connection = services.daemon.connection else { throw Failure.unavailable }
        let ids = surfaces.compactMap { UInt64($0).map(SurfaceID.init(rawValue:)) }
        guard ids.count == surfaces.count else { throw Failure.invalidSurfaces }
        try await connection.closeTabs(ids, endTerminals: true)
    }

    /// The sibling builds and their movable sessions, for `session.transfer.peers` and `.pull`.
    /// Throws ``Failure/peerRefused`` when no peer has sessions and at least
    /// one refused the connection (classic's default `cmuxOnly` socket mode
    /// admits only its own terminals).
    /// With `only` (a socket path or tag), a refusal by that peer throws.
    nonisolated func discover(only source: String? = nil) async throws -> [SessionTransferPeer] {
        let current = await mainWork.apply(.automation, owner: "SessionTransfer.discover") { [weak self] in
            self?.services?.environment.launch
        }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let paths = ControlSocketPath.shared.peerSocketPaths().filter { $0 != current?.socketPath }
        var peers: [SessionTransferPeer] = []
        var refused = false
        for path in paths where Self.isOwnedSocket(path) {
            let identify: TransferJSONValue
            do {
                identify = try await ControlPeerClient.request(path: path, method: "system.identify")
            } catch ControlPeerClient.Failure.refused {
                if source == path { throw Failure.peerRefused }
                refused = true
                continue
            } catch {
                continue
            }
            // Classic answers without `pid` and `tag` (its bundle id carries the tag);
            // shipped classic nightlies answer only `socket_path`, `focused` and `caller`.
            guard let fields = identify.objectValue, fields["pid"]?.intValue != ownPID else { continue }
            let app = fields["app"]?.stringValue ?? "cmux"
            let build = fields["build"]?.stringValue ?? fields["version"]?.stringValue ?? ""
            let tag = fields["tag"]?.stringValue ?? ControlSocketPath.shared.bundleTag(fields["bundle_identifier"]?.stringValue)
            let items: [SessionTransferItem]
            if let list = try? await ControlPeerClient.request(path: path, method: "session.transfer.list"),
               let records = list["sessions"]?.arrayValue {
                items = records.compactMap { SessionTransferItem(json: $0) }
            } else {
                items = await Self.discoverClassicItems(path: path)
            }
            if !items.isEmpty {
                peers.append(SessionTransferPeer(path: path, app: app, build: build, tag: tag,
                                                 pid: Int32(clamping: fields["pid"]?.intValue ?? 0), items: items))
            }
        }
        if peers.isEmpty, refused { throw Failure.peerRefused }
        return peers
    }

    /// A peer socket must be a socket this user owns: `/tmp` is shared, and a
    /// peer chooses the commands its sessions reopen with.
    nonisolated static func isOwnedSocket(_ path: String) -> Bool {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of `path` made for the call and writes one struct stat
        // into `info`, a local live for the call.
        guard unsafe blockingLstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    private func move(_ item: SessionTransferItem, from peer: SessionTransferPeer, interrupt: Bool, cwd: String?) async throws {
        if item.kind == .chat { return try await moveChat(item, from: peer, interrupt: interrupt, cwd: cwd) }
        _ = try await create(item)
        try await completeOnPeer(item: item, peer: peer)
    }

    /// Opens records read from classic's files (scripts/cmux-next/classic-to-next.py):
    /// `agent` {harness, session, cwd?, name?} becomes an agent chat resumed by its
    /// session id; `workspace` {name?, cwd?, terminals: [{title?, cwd?, command?}], layout?}
    /// becomes one workspace with a terminal per entry, in `layout`'s panes and
    /// splits (`TransferLayout`), else as tabs of one pane. Nothing is closed anywhere.
    func open(agent: [String: TransferJSONValue]?, workspace: [String: TransferJSONValue]?) async throws -> TransferJSONValue {
        if let agent {
            guard let harness = agent["harness"]?.stringValue, let session = agent["session"]?.stringValue else {
                throw Failure.missingAgentID
            }
            let item = SessionTransferItem(sourceSurface: session, workspace: "", kind: .agent, title: agent["name"]?.stringValue ?? "",
                                           cwd: agent["cwd"]?.stringValue, sshTarget: nil, command: nil,
                                           agentHarness: harness, agentSessionID: session)
            return ["workspace": .string(try await create(item))]
        }
        guard let workspace else { throw Failure.noSessions }
        let name = workspace["name"]?.stringValue
        let cwd = workspace["cwd"]?.stringValue
        let terminals = (workspace["terminals"]?.arrayValue ?? []).compactMap(\.objectValue)
        let items = (terminals.isEmpty ? [[:]] : terminals).map { terminal in
            SessionTransferItem(sourceSurface: "", workspace: "", kind: .terminal, title: terminal["title"]?.stringValue ?? "",
                                cwd: terminal["cwd"]?.stringValue ?? cwd, sshTarget: nil, command: terminal["command"]?.stringValue,
                                agentHarness: nil, agentSessionID: nil)
        }
        // A layout that does not name each terminal once is left out: the terminals still open, as tabs.
        let layout = TransferLayout(json: workspace["layout"], terminals: items.count) ?? .pane(Array(items.indices))
        let id = try await create(items[layout.terminals[0]], workspaceName: name)
        guard items.count > 1 else { return ["workspace": .string(id)] }
        guard let services, let connection = services.daemon.connection,
              let pane = try await firstPane(of: id, connection: connection) else { throw Failure.unavailable }
        try await open(layout, items: items, in: pane, workspace: id, connection: connection)
        return ["workspace": .string(id)]
    }

    /// Creates `item` in a new workspace of the active window and returns the workspace id.
    private func create(_ item: SessionTransferItem, workspaceName: String? = nil) async throws -> String {
        guard let services else { throw Failure.unavailable }
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        let name = workspaceName ?? (item.title.isEmpty ? nil : item.title)
        switch item.kind {
        case .agent:
            guard let session = item.agentSessionID, let harness = item.agentHarness else { throw Failure.missingAgentID }
            var spawn = WorkspaceSpawn(cwd: item.cwd, name: name)
            spawn.firstChat = AgentPaneSeed(cwd: item.cwd, adopt: AgentPaneAdopt(harness: harness, agentSessionId: session))
            let id = try await services.windows.createWorkspace(spawn, into: target)
            // createWorkspace falls back to a plain terminal when no agent can be
            // hosted yet; only an opened conversation tab counts, so a source chat
            // is never closed for a shell.
            guard try await hasConversationTab(id) else { throw Failure.agentNotOpened }
            return id
        case .chat:
            // Opened by `move` once the chat is in this build's acpmux.
            throw Failure.missingAgentID
        case .terminal:
            let command = item.command ?? item.sshTarget.map { "exec ssh -- \(Self.shellQuote($0))" }
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: item.cwd, name: name, command: command), into: target)
            if !item.title.isEmpty, let connection = services.daemon.connection,
               let workspace = try? await connection.listWorkspaces(),
               let screen = workspace.workspaces.first(where: { $0.key?.rawValue == id })?.screens.first,
               let surface = screen.layout.paneIDs.compactMap({ paneID in screen.panes.first(where: { $0.id == paneID }) }).flatMap(\.tabs).first?.surface {
                try? await connection.renameTab(surface, to: item.title)
            }
            return id
        }
    }

    /// Whether the store lists a conversation tab in `workspace`. The tree
    /// mirrors the create asynchronously, so this waits for it, up to
    /// `conversationTabLimit`: an ``ObservedCondition`` on the workspace's index entry, bounded by a
    /// ``MainDeadline`` (automation: a sibling build asked).
    func hasConversationTab(_ workspace: String) async throws -> Bool {
        guard let services else { throw Failure.unavailable }
        let store = services.daemon.store
        let listed: @MainActor () -> Bool = {
            store.workspace(id: workspace)?.screens.flatMap(\.panes).flatMap(\.tabs).contains { $0.kind == .conversation } ?? false
        }
        await ObservedCondition(owner: "SessionTransfer.conversationTab", .automation, on: mainWork)
            .until(timeout: Self.conversationTabLimit, deadlines: services.mainDeadlines, listed)
        return listed()
    }

    private func firstPane(of workspace: String, connection: DaemonConnection) async throws -> CmuxNextDaemon.PaneID? {
        let listed = try await connection.listWorkspaces()
        return listed.workspaces.first(where: { $0.key?.rawValue == workspace })?.screens.first?.layout.paneIDs.first
    }

    func completeOnPeer(item: SessionTransferItem, peer: SessionTransferPeer) async throws {
        do {
            _ = try await ControlPeerClient.request(path: peer.path, method: "session.transfer.complete",
                                                    params: ["surfaces": .array([.string(item.sourceSurface)])])
        } catch let error as ControlPeerClient.Failure where Self.isMissingTransferMethod(error) {
            // Classic builds expose the normal v2 close method instead of the
            // additive transfer acknowledgement method.
            do {
                _ = try await ControlPeerClient.request(path: peer.path, method: "surface.close", params: [
                    "workspace_id": .string(item.workspace),
                    "surface_id": .string(item.sourceSurface),
                    "force": .bool(true),
                ])
            } catch ControlPeerClient.Failure.peer(let control) where control.code == "invalid_state" {
                // Classic refuses to close a workspace's last surface; the
                // moved terminal was its only one, so close the workspace.
                _ = try await ControlPeerClient.request(path: peer.path, method: "workspace.close", params: [
                    "workspace_id": .string(item.workspace),
                    "force": .bool(true),
                ])
            }
        }
    }

    private static func isMissingTransferMethod(_ error: ControlPeerClient.Failure) -> Bool {
        guard case .peer(let control) = error else { return false }
        return ["method_not_found", "unknown_method", "unsupported", "unavailable"].contains(control.code)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case Failure.noSessions:
            String(localized: "sessionTransfer.error.noSessions", defaultValue: "No sessions are available to move from another cmux build.", bundle: .module)
        case Failure.missingAgentID:
            String(localized: "sessionTransfer.error.missingAgentID", defaultValue: "The selected agent has no resumable session ID.", bundle: .module)
        case Failure.agentNotOpened:
            String(localized: "sessionTransfer.error.agentNotOpened", defaultValue: "The agent chat did not open in cmux-next, so the source was left as it was.", bundle: .module)
        case Failure.unavailable:
            String(localized: "sessionTransfer.error.unavailable", defaultValue: "Session transfer is unavailable while cmux is starting.", bundle: .module)
        case Failure.peerRefused:
            String(localized: "sessionTransfer.error.peerRefused",
                   defaultValue: "The other cmux build only accepts connections from its own terminals. Set its socket control mode to Automation, then try again.",
                   bundle: .module)
        case Failure.chatInChats:
            String(localized: "sessionTransfer.error.chatInChats",
                   defaultValue: "The agent chat moved to this build but its tab did not open yet. Open it from Chats.", bundle: .module)
        case Failure.sourceAgentsStopped:
            String(localized: "sessionTransfer.error.sourceAgentsStopped",
                   defaultValue: "The other build's agent service is not running. Open that build's chat once, then try again.", bundle: .module)
        case Failure.chatFolderMissing(let folder):
            String(localized: "sessionTransfer.error.chatFolderMissing",
                   defaultValue: "This chat works in \(folder), which isn't on this Mac, so it stayed in the other build. Create that folder here, then move the chat again.",
                   bundle: .module)
        case Failure.chatNotMoved(let reason):
            String(localized: "sessionTransfer.error.chatNotMoved", defaultValue: "The agent chat did not move: \(reason)", bundle: .module)
        case Failure.invalidSurfaces:
            String(localized: "sessionTransfer.error.invalidSurfaces", defaultValue: "The source build returned invalid session identifiers.", bundle: .module)
        case let failure as ControlPeerClient.Failure:
            failure.description
        default:
            String(localized: "sessionTransfer.error.failed", defaultValue: "Could not move sessions from the other cmux build.", bundle: .module)
        }
    }

    nonisolated enum Failure: Error {
        case noSessions, missingAgentID, unavailable, invalidSurfaces, peerRefused, agentNotOpened
        /// acpmux refused or failed the move (its message); the chat stays in the source build.
        case chatNotMoved(String)
        /// The chat's folder (its path) is not on this machine; the chat stays in the source build.
        case chatFolderMissing(String)
        /// The chat is (or is still moving) here, with no tab yet.
        case chatInChats
        /// The source build's acpmux does not answer.
        case sourceAgentsStopped
    }
}

private extension CmuxNextSettings.JSONValue {
    nonisolated static func optional(_ value: String?) -> CmuxNextSettings.JSONValue { value.map(CmuxNextSettings.JSONValue.string) ?? .null }
}
