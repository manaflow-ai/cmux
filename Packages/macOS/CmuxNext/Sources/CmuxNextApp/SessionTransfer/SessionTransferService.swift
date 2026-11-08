import CmuxNextCompat
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSessionTransfer
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

typealias TransferJSONValue = CmuxNextSettings.JSONValue

/// Discovers live sibling builds and performs an acknowledge-then-close move.
/// The destination creates every item first; a source is only asked to close
/// after the corresponding destination operation succeeds. A person runs it
/// from the palette (Move Sessions from Another cmux Build…, `SessionMoveFromBuild`);
/// scripts and agents use the control socket (`session.transfer.peers` /
/// `session.transfer.pull`).
@MainActor
final class SessionTransferService {
    private(set) weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    /// How long a moved agent waits for its conversation tab (the old poll's 20 × 250 ms).
    static let conversationTabLimit: Duration = .seconds(5)

    /// Moves the selected sessions (all of them when `ids` is empty) from the one
    /// peer named by `source` (its socket path or tag). A terminal's move opens a new
    /// shell in the same folder and ends the source's process; a chat's moves the chat
    /// itself (``moveChat(_:interrupt:cwd:)``), refused while it runs a turn unless `interrupt`, and
    /// into folder `cwd` here when given (a chat whose folder is not on this machine).
    /// One item's failure never stops the others; each is reported. With `idleTerminalsOnly`
    /// (the palette's picker, which offers only idle terminals), each terminal is asked again
    /// right before its move and stays when it is no longer idle at its shell
    /// (``Failure/terminalBusy(_:)``): the picker's answer may be minutes old.
    func pull(source: String, ids: Set<String> = [], interrupt: Bool = false, cwd: String? = nil,
              idleTerminalsOnly: Bool = false) async throws -> TransferJSONValue {
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
                try await move(item, from: peer, interrupt: interrupt, cwd: cwd, idleTerminalsOnly: idleTerminalsOnly)
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

    /// Closes `surfaces` and ends their terminals. With `idleOnly` (a taker that offered only
    /// idle terminals), first asks each its foreground program and closes none when one is no
    /// longer idle at its shell (``Failure/terminalBusy(_:)``, the control code ``busyCode``).
    func complete(surfaces: [String], idleOnly: Bool = false) async throws {
        guard let services, let connection = services.daemon.connection else { throw Failure.unavailable }
        let ids = surfaces.compactMap { UInt64($0).map(SurfaceID.init(rawValue:)) }
        guard ids.count == surfaces.count else { throw Failure.invalidSurfaces }
        if idleOnly {
            let programs = await foregroundPrograms(surfaces)
            for surface in surfaces {
                // Missing: no answer, which is not idle. `.some(nil)`: its shell only.
                guard let program = programs[surface] else { throw Failure.terminalBusy(SessionMoveSelection.becameUnknown) }
                if let program {
                    throw Failure.terminalBusy(program.isEmpty ? SessionMoveSelection.becameUnknown : SessionMoveSelection.becameBusy(program))
                }
            }
        }
        try await connection.closeTabs(ids, endTerminals: true)
    }

    /// Each local terminal's foreground program by surface, for `session.transfer.list`'s
    /// `idle` and `foreground_program`, asked at once with a short deadline. A nil program:
    /// its shell only. A terminal missing from it did not answer or reported no foreground,
    /// so a taker treats it as busy: a move ends it, so unlike a close, no answer is not idle.
    func foregroundPrograms(_ surfaces: [String]) async -> [String: String?] {
        guard let connection = services?.daemon.connection else { return [:] }
        return await withTaskGroup(of: (String, String??).self) { group in
            for surface in surfaces {
                guard let id = UInt64(surface).map(SurfaceID.init(rawValue:)) else { continue }
                group.addTask {
                    let info = await connection.readProcessInfo(id, timeout: .milliseconds(500))
                    guard let info, info.foregroundExecutable?.isEmpty == false else { return (surface, nil) }
                    return (surface, .some(info.runningProgram))
                }
            }
            var programs: [String: String?] = [:]
            for await (surface, program) in group {
                if let program { programs[surface] = .some(program) }
            }
            return programs
        }
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
            // A cmux-next source asks each terminal for its foreground program (up to half a second).
            if let list = try? await ControlPeerClient.request(path: path, method: "session.transfer.list", timeout: .seconds(5)),
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
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    private func move(_ item: SessionTransferItem, from peer: SessionTransferPeer, interrupt: Bool, cwd: String?,
                      idleTerminalsOnly: Bool) async throws {
        if item.kind == .chat { return try await moveChat(item, from: peer, interrupt: interrupt, cwd: cwd) }
        if item.kind == .terminal, idleTerminalsOnly {
            // Moving ends the terminal there, so ask its build now, not what discovery saw:
            // a terminal idle when picked may run `vim` with unsaved work by now.
            let list = try? await ControlPeerClient.request(path: peer.path, method: "session.transfer.list", timeout: .seconds(5))
            if let refusal = SessionMoveSelection.handoffRefusal(surface: item.sourceSurface, list: list) {
                throw Failure.terminalBusy(refusal)
            }
        }
        let created = try await create(item)
        guard item.kind == .terminal, idleTerminalsOnly else { return try await completeOnPeer(item: item, peer: peer) }
        do {
            // The source checks again as it closes (`idle_only`): the terminal may have started a
            // program while the shell here opened. Refused, the new shell here closes again.
            try await completeOnPeer(item: item, peer: peer, idleOnly: true)
        } catch ControlPeerClient.Failure.peer(let control) where control.code == Self.busyCode {
            if let connection = services?.daemon.connection {
                _ = try? await connection.closeWorkspace(WorkspaceKey(rawValue: created), endTerminals: true)
            }
            throw Failure.terminalBusy(control.message)
        }
    }

    /// The `session.transfer.complete` error code for an `idle_only` terminal that is not idle.
    nonisolated static let busyCode = "terminal_busy"

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
    /// `conversationTabLimit`.
    func hasConversationTab(_ workspace: String) async throws -> Bool {
        guard let store = services?.daemon.store else { throw Failure.unavailable }
        let listed = Task { @MainActor () -> Bool in
            let opened = ObservationStream({
                store.workspaces.first(where: { $0.key?.rawValue == workspace })?.screens
                    .flatMap(\.panes).flatMap(\.tabs).contains(where: { $0.kind == .conversation }) ?? false
            })
            for await found in opened where found { return true }
            return false
        }
        let bound = DemandTimer(owner: "SessionTransfer.conversationTab")
        bound.schedule(after: Self.conversationTabLimit) { @MainActor in
            listed.cancel()
        }
        let found = await listed.value
        bound.cancel()
        return found
    }

    private func firstPane(of workspace: String, connection: DaemonConnection) async throws -> CmuxNextDaemon.PaneID? {
        let listed = try await connection.listWorkspaces()
        return listed.workspaces.first(where: { $0.key?.rawValue == workspace })?.screens.first?.layout.paneIDs.first
    }

    func completeOnPeer(item: SessionTransferItem, peer: SessionTransferPeer, idleOnly: Bool = false) async throws {
        do {
            var params: [String: TransferJSONValue] = ["surfaces": .array([.string(item.sourceSurface)])]
            if idleOnly { params["idle_only"] = .bool(true) }
            _ = try await ControlPeerClient.request(path: peer.path, method: "session.transfer.complete", params: params)
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
        case Failure.terminalBusy(let reason):
            reason
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
        /// A terminal picked while idle runs a program now, or its build can no longer tell
        /// (the reason, `SessionMoveSelection.handoffRefusal`); it stays in the source build.
        case terminalBusy(String)
    }
}
