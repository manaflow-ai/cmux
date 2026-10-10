import AppKit
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Observation

private typealias TransferJSONValue = CmuxNextSettings.JSONValue

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

struct SessionTransferOffer: Sendable, Equatable {
    let itemCount: Int
    let sourceBuilds: [String]
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
/// after the corresponding destination operation succeeds.
@MainActor
@Observable
final class SessionTransferService {
    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    /// A launch offer for the sidebar notice. It is intentionally local to the
    /// destination build: dismissing it never mutates a source build.
    private(set) var offer: SessionTransferOffer?

    init(services: AppServices) { self.services = services }

    deinit { activeTask?.cancel() }

    /// A newer build announces a sibling only when it actually has movable
    /// records. The action remains the single mutation path when the person
    /// clicks the palette command or invokes `session.moveHere` by CLI.
    func announceAvailablePeers() {
        Task { [weak self] in
            guard let self, offer == nil else { return }
            guard let peers = try? await discover() else { return }
            let count = peers.reduce(0) { $0 + $1.items.count }
            guard count > 0 else { return }
            offer = SessionTransferOffer(itemCount: count, sourceBuilds: peers.map(\.build))
        }
    }

    func dismissOffer() { offer = nil }

    func start(source: String? = nil, ids: Set<String> = []) {
        activeTask?.cancel()
        offer = nil
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let peers = try await discover()
                let selected = peers.flatMap { peer -> [(SessionTransferPeer, SessionTransferItem)] in
                    guard source == nil || source == peer.path || source == peer.tag else { return [] }
                    return peer.items.filter { ids.isEmpty || ids.contains($0.id) }.map { (peer, $0) }
                }
                guard !selected.isEmpty else { throw Failure.noSessions }
                for (peer, item) in selected { try await move(item, from: peer) }
            } catch is CancellationError {
                return
            } catch {
                guard let services else { return }
                services.refusalHUD.show(Self.message(for: error), in: services.windows.active?.window ?? NSApp.keyWindow)
            }
        }
    }

    func complete(surfaces: [String]) async throws {
        guard let services, let connection = services.daemon.connection else { throw Failure.unavailable }
        let ids = surfaces.compactMap { UInt64($0).map(SurfaceID.init(rawValue:)) }
        guard ids.count == surfaces.count else { throw Failure.invalidSurfaces }
        try await connection.closeTabs(ids, endTerminals: true)
    }

    /// Builds the list used by the launch notice and by `session.transfer.list`.
    nonisolated func discover() async throws -> [SessionTransferPeer] {
        let current = await MainActor.run { services?.environment.launch }
        let paths = ControlSocketPath.shared.peerSocketPaths().filter { $0 != current?.socketPath }
        var peers: [SessionTransferPeer] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            guard let identify = try? await ControlPeerClient.request(path: path, method: "system.identify"),
                  let fields = identify.objectValue,
                  let app = fields["app"]?.stringValue,
                  let build = fields["build"]?.stringValue,
                  let pid = fields["pid"]?.intValue else { continue }
            let tag = fields["tag"]?.stringValue
            let items: [SessionTransferItem]
            if let list = try? await ControlPeerClient.request(path: path, method: "session.transfer.list"),
               let records = list["sessions"]?.arrayValue {
                items = records.compactMap { SessionTransferItem(json: $0) }
            } else {
                items = await Self.discoverClassicItems(path: path)
            }
            if !items.isEmpty {
                peers.append(SessionTransferPeer(path: path, app: app, build: build,
                                                 tag: tag, pid: Int32(clamping: pid), items: items))
            }
        }
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
            if let daemon = services.machines.daemon(forWorkspace: id), let connection = daemon.connection,
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
            _ = try await ControlPeerClient.request(path: peer.path, method: "surface.close", params: [
                "workspace_id": .string(item.workspace),
                "surface_id": .string(item.sourceSurface),
                "force": .bool(true),
            ])
        }
    }

    private static func discoverClassicItems(path: String) async -> [SessionTransferItem] {
        guard let result = try? await ControlPeerClient.request(path: path, method: "workspace.list"),
              let workspaces = result["workspaces"]?.arrayValue else { return [] }
        var items: [SessionTransferItem] = []
        for workspace in workspaces {
            guard let object = workspace.objectValue,
                  let workspaceID = object["id"]?.stringValue ?? object["ref"]?.stringValue else { continue }
            let fallbackCWD = object["current_directory"]?.stringValue
            guard let result = try? await ControlPeerClient.request(path: path, method: "surface.list",
                                                                     params: ["workspace_id": .string(workspaceID)]),
                  let surfaces = result["surfaces"]?.arrayValue else { continue }
            for surface in surfaces {
                guard let item = Self.classicItem(surface, workspace: workspaceID, fallbackCWD: fallbackCWD) else { continue }
                items.append(item)
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
        let bindingHarness = binding?["harness"]?.stringValue
        let bindingKind = binding?["kind"]?.stringValue
        let harness = object["agent"]?.stringValue ?? bindingHarness ?? bindingKind
        let directSession = object["agent_session"]?.stringValue
        let bindingSession = binding?["session_id"]?.stringValue
        let bindingCheckpoint = binding?["checkpoint_id"]?.stringValue
        let session = directSession ?? bindingSession ?? bindingCheckpoint
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

    private static func message(for error: Error) -> String {
        switch error {
        case Failure.noSessions: "No sessions are available to move from another cmux build."
        case Failure.missingAgentID: "The selected agent has no resumable session id."
        case Failure.unavailable: "Session transfer is unavailable while cmux is starting."
        case Failure.invalidSurfaces: "The source build returned invalid session identifiers."
        default: "Could not move sessions from the other cmux build."
        }
    }

    enum Failure: Error { case noSessions, missingAgentID, unavailable, invalidSurfaces }
}

private extension CmuxNextSettings.JSONValue {
    static func optional(_ value: String?) -> CmuxNextSettings.JSONValue { value.map(CmuxNextSettings.JSONValue.string) ?? .null }
}
