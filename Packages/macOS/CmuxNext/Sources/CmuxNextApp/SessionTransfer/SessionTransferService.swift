import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

typealias TransferJSONValue = CmuxNextSettings.JSONValue

/// A live tab that another local cmux build can hand to this App.
struct SessionTransferItem: Sendable, Equatable, Identifiable {
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

    enum Kind: String, Sendable { case terminal, agent }
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

struct SessionTransferPeer: Sendable {
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

    /// Moves the selected sessions (all of them when `ids` is empty) from the
    /// peers matching `source` (a socket path or tag; any when nil). One
    /// item's failure never stops the others; each is reported.
    func pull(source: String? = nil, ids: Set<String> = []) async throws -> TransferJSONValue {
        let peers = try await discover()
        let selected = peers.flatMap { peer -> [(SessionTransferPeer, SessionTransferItem)] in
            guard source == nil || source == peer.path || source == peer.tag else { return [] }
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
    nonisolated func discover() async throws -> [SessionTransferPeer] {
        let current = await MainActor.run { services?.environment.launch }
        let paths = ControlSocketPath.shared.peerSocketPaths().filter { $0 != current?.socketPath }
        var peers: [SessionTransferPeer] = []
        var refused = false
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let identify: JSONValue
            do {
                identify = try await ControlPeerClient.request(path: path, method: "system.identify")
            } catch ControlPeerClient.Failure.refused {
                refused = true
                continue
            } catch {
                continue
            }
            // Classic answers without `pid` and `tag`; its bundle id carries the tag.
            guard let fields = identify.objectValue,
                  let app = fields["app"]?.stringValue,
                  let build = fields["build"]?.stringValue else { continue }
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

    private func move(_ item: SessionTransferItem, from peer: SessionTransferPeer) async throws {
        guard let services else { throw Failure.unavailable }
        let target = services.windows.targetWindow(preferring: services.windows.active?.state.id)
        switch item.kind {
        case .agent:
            guard let session = item.agentSessionID, let harness = item.agentHarness else { throw Failure.missingAgentID }
            var spawn = WorkspaceSpawn(cwd: item.cwd, name: item.title)
            spawn.firstChat = AgentPaneSeed(cwd: item.cwd, adopt: AgentPaneAdopt(harness: harness, agentSessionId: session))
            _ = try await services.windows.createWorkspace(spawn, into: target)
        case .terminal:
            let command = item.command ?? item.sshTarget.map { "exec ssh \(Self.shellQuote($0))" }
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: item.cwd, name: item.title, command: command), into: target)
            if !item.title.isEmpty, let daemon = services.machines.daemon(forWorkspace: id), let connection = daemon.connection,
               let workspace = try? await connection.listWorkspaces(),
               let screen = workspace.workspaces.first(where: { $0.key?.rawValue == id })?.screens.first,
               let surface = screen.layout.paneIDs.compactMap({ paneID in screen.panes.first(where: { $0.id == paneID }) }).flatMap(\.tabs).first?.surface {
                try? await connection.renameTab(surface, to: item.title)
            }
        }
        try await completeOnPeer(item: item, peer: peer)
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
        } ?? binding?["checkpoint_id"]?.stringValue
        let isAgent = harness != nil && session != nil
        let command = object["initial_command"]?.stringValue ?? binding?["command"]?.stringValue
        let cwd = object["requested_working_directory"]?.stringValue ?? binding?["cwd"]?.stringValue ?? fallbackCWD
        let sshTarget = object["ssh_target"]?.stringValue ?? Self.sshTarget(from: command)
        let title = object["title"]?.stringValue ?? ""
        return SessionTransferItem(sourceSurface: sourceSurface, workspace: workspace,
                                   kind: isAgent ? SessionTransferItem.Kind.agent : SessionTransferItem.Kind.terminal, title: title, cwd: cwd,
                                   sshTarget: sshTarget, command: isAgent ? nil : command,
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

    enum Failure: Error { case noSessions, missingAgentID, unavailable, invalidSurfaces, peerRefused }
}

private extension CmuxNextSettings.JSONValue {
    static func optional(_ value: String?) -> CmuxNextSettings.JSONValue { value.map(CmuxNextSettings.JSONValue.string) ?? .null }
}
