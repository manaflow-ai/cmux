import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
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

    nonisolated enum Kind: String, Sendable { case terminal, agent }
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
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    /// Moves the selected sessions (all of them when `ids` is empty) from the one
    /// peer named by `source` (its socket path or tag). A move opens a new shell
    /// in the same folder and ends the source's process. One item's failure
    /// never stops the others; each is reported.
    func pull(source: String, ids: Set<String> = []) async throws -> TransferJSONValue {
        let peers = try await discover(only: source)
        let selected = peers.flatMap { peer -> [(SessionTransferPeer, SessionTransferItem)] in
            guard source == peer.path || source == peer.tag else { return [] }
            return peer.items.filter { ids.isEmpty || ids.contains($0.id) }.map { (peer, $0) }
        }
        guard !selected.isEmpty else { throw Failure.noSessions }
        var moved: [TransferJSONValue] = []
        var failed: [TransferJSONValue] = []
        for (peer, item) in selected {
            do {
                try await move(item, from: peer)
                moved.append(item.json)
            } catch {
                failed.append(["surface": .string(item.id), "source": .string(peer.path), "error": .string(Self.message(for: error))])
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
        let current = await MainActor.run { services?.environment.launch }
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
    private nonisolated static func isOwnedSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    private func move(_ item: SessionTransferItem, from peer: SessionTransferPeer) async throws {
        _ = try await create(item)
        try await completeOnPeer(item: item, peer: peer)
    }

    /// Opens records read from classic's files (scripts/cmux-next/classic-to-next.py):
    /// `agent` {harness, session, cwd?, name?} becomes an agent chat resumed by its
    /// session id; `workspace` {name?, cwd?, terminals: [{title?, cwd?, command?}]}
    /// becomes one workspace with a terminal tab per entry. Nothing is closed anywhere.
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
        let id = try await create(items[0], workspaceName: name)
        guard items.count > 1 else { return ["workspace": .string(id)] }
        guard let services, let connection = services.daemon.connection,
              let pane = try await firstPane(of: id, connection: connection) else { throw Failure.unavailable }
        for item in items.dropFirst() {
            try await connection.newTab(in: pane, options: SpawnOptions(cwd: item.cwd, command: item.command,
                                                                      name: item.title.isEmpty ? nil : item.title))
        }
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

    private func hasConversationTab(_ workspace: String) async throws -> Bool {
        guard let connection = services?.daemon.connection else { throw Failure.unavailable }
        for _ in 0..<20 {
            let listed = try await connection.listWorkspaces()
            if let found = listed.workspaces.first(where: { $0.key?.rawValue == workspace }),
               found.screens.flatMap(\.panes).flatMap(\.tabs).contains(where: { $0.conversation != nil }) {
                return true
            }
            try await Task.sleep(for: .milliseconds(250))  // the tree mirrors the create asynchronously
        }
        return false
    }

    private func firstPane(of workspace: String, connection: DaemonConnection) async throws -> CmuxNextDaemon.PaneID? {
        let listed = try await connection.listWorkspaces()
        return listed.workspaces.first(where: { $0.key?.rawValue == workspace })?.screens.first?.layout.paneIDs.first
    }

    private func completeOnPeer(item: SessionTransferItem, peer: SessionTransferPeer) async throws {
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

    /// Classic's `workspace.list` covers one window, so walk `window.list`.
    private static func discoverClassicItems(path: String) async -> [SessionTransferItem] {
        let windows = (try? await ControlPeerClient.request(path: path, method: "window.list"))?["windows"]?.arrayValue ?? []
        let windowIDs: [String?] = windows.isEmpty ? [nil] : windows.compactMap { $0["id"]?.stringValue }
        var items: [SessionTransferItem] = []
        for windowID in windowIDs {
            let windowParams: [String: TransferJSONValue] = windowID.map { ["window_id": .string($0)] } ?? [:]
            guard let result = try? await ControlPeerClient.request(path: path, method: "workspace.list", params: windowParams),
                  let workspaces = result["workspaces"]?.arrayValue else { continue }
            for workspace in workspaces {
                guard let object = workspace.objectValue,
                      let workspaceID = object["id"]?.stringValue ?? object["ref"]?.stringValue else { continue }
                let fallbackCWD = object["current_directory"]?.stringValue
                var params = windowParams
                params["workspace_id"] = .string(workspaceID)
                guard let result = try? await ControlPeerClient.request(path: path, method: "surface.list", params: params),
                      let surfaces = result["surfaces"]?.arrayValue else { continue }
                for surface in surfaces {
                    guard let item = Self.classicItem(surface, workspace: workspaceID, fallbackCWD: fallbackCWD) else { continue }
                    items.append(item)
                }
            }
        }
        return items
    }

    private static func classicItem(_ value: TransferJSONValue, workspace: String, fallbackCWD: String?) -> SessionTransferItem? {
        guard let object = value.objectValue,
              let sourceSurface = object["id"]?.stringValue ?? object["ref"]?.stringValue else { return nil }
        let type = object["type"]?.stringValue ?? ""
        guard type == "terminal" || type == "pty" else { return nil }
        let binding = object["resume_binding"]?.objectValue
        // Classic keeps the agent's session id inside its resume command
        // (`claude --resume <id>`, `codex resume <id>`).
        let harness = binding?["kind"]?.stringValue.flatMap { ["claude", "codex"].contains($0) ? $0 : nil }
        let session = harness.flatMap { harness in
            [binding?["command"]?.stringValue, binding?["launch_command"]?.stringValue]
                .lazy.compactMap { Self.agentSessionID(harness: harness, command: $0) }.first
        }
        let isAgent = harness != nil && session != nil
        let command = object["initial_command"]?.stringValue ?? binding?["command"]?.stringValue
        // Only an SSH command is replayed; a classic terminal's other launch
        // command may be one-shot (a deploy), so it reopens as a shell.
        let cwd = object["requested_working_directory"]?.stringValue ?? binding?["cwd"]?.stringValue ?? fallbackCWD
        let sshTarget = object["ssh_target"]?.stringValue ?? Self.sshTarget(from: command)
        let title = object["title"]?.stringValue ?? ""
        return SessionTransferItem(sourceSurface: sourceSurface, workspace: workspace,
                                   kind: isAgent ? SessionTransferItem.Kind.agent : SessionTransferItem.Kind.terminal, title: title, cwd: cwd,
                                   sshTarget: sshTarget, command: nil,
                                   agentHarness: isAgent ? harness : nil,
                                   agentSessionID: isAgent ? session : nil)
    }

    /// The session id in a classic resume command: `claude --resume|-r|--session-id <id>`
    /// or `codex resume <id>`.
    static func agentSessionID(harness: String, command: String?) -> String? {
        guard let command else { return nil }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        let flags: Set<String> = harness == "codex" ? ["resume"] : ["--resume", "-r", "--session-id"]
        guard let index = tokens.firstIndex(where: flags.contains), index + 1 < tokens.count else { return nil }
        let id = tokens[index + 1]
        return id.isEmpty || id.hasPrefix("-") ? nil : id
    }

    private static func sshTarget(from command: String?) -> String? {
        guard let command else { return nil }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let index = tokens.firstIndex(where: { $0 == "ssh" || $0.hasSuffix("/ssh") }) else { return nil }
        var skipNext = false
        for token in tokens.dropFirst(index + 1) {
            if skipNext { skipNext = false; continue }
            if token == "--" { continue }
            if token == "-p" || token == "-o" || token == "-J" { skipNext = true; continue }
            if token.hasPrefix("-") { continue }
            return token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return nil
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
            String(localized: "sessionTransfer.error.missingAgentID", defaultValue: "The selected agent has no resumable session id.", bundle: .module)
        case Failure.agentNotOpened:
            String(localized: "sessionTransfer.error.agentNotOpened", defaultValue: "The agent chat did not open in cmux-next, so the source was left as it was.", bundle: .module)
        case Failure.unavailable:
            String(localized: "sessionTransfer.error.unavailable", defaultValue: "Session transfer is unavailable while cmux is starting.", bundle: .module)
        case Failure.peerRefused:
            String(localized: "sessionTransfer.error.peerRefused",
                   defaultValue: "The other cmux build only accepts connections from its own terminals. Set its socket control mode to Automation, then try again.",
                   bundle: .module)
        case Failure.invalidSurfaces:
            String(localized: "sessionTransfer.error.invalidSurfaces", defaultValue: "The source build returned invalid session identifiers.", bundle: .module)
        case let failure as ControlPeerClient.Failure:
            failure.description
        default:
            String(localized: "sessionTransfer.error.failed", defaultValue: "Could not move sessions from the other cmux build.", bundle: .module)
        }
    }

    nonisolated enum Failure: Error { case noSessions, missingAgentID, unavailable, invalidSurfaces, peerRefused, agentNotOpened }
}

private extension CmuxNextSettings.JSONValue {
    nonisolated static func optional(_ value: String?) -> CmuxNextSettings.JSONValue { value.map(CmuxNextSettings.JSONValue.string) ?? .null }
}
