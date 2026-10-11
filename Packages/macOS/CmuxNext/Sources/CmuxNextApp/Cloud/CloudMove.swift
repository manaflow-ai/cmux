import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

/// Move to Cloud (cmuxterm-hq#1874 slice 3): the one action behind the palette's
/// "Move to Cloud", the tab and chat right-click menus and `cmux cloud move`.
/// For a chat tab of this Mac it reuses a Cloud machine (the named one, else a
/// connected one, else any, else a new one), copies the chat's folder there
/// (`cmux link sync push`), moves the chat (`cmux link agent move`), and shows
/// it on that machine: a Cloud workspace whose terminal runs in the synced
/// folder and whose chat tab is bound to the moved session through the
/// machine's store, so the tab attaches through that machine and carries its
/// badge. This Mac's tab, whose chat the move closed, closes.
///
/// The chat keeps its session, history, draft and queue, not its tab id: a tab
/// lives in exactly one machine's store, which mints its ids, and a chat on a
/// machine attaches by a tab of that machine's own store
/// (`agent-session-attach` names a surface of the daemon's store).
///
/// Progress and failures are toasts on the window, never a sheet. A move that
/// may still finish offers Retry, which runs this action again: the CLIs are
/// idempotent (a second sync writes only changes, and a rerun of the move
/// resolves an unresolved one first). Bring Back is the reverse (slice 4).
@MainActor
struct CloudMove {
    static let action: ActionID = "cloudMove"
    let services: AppServices

    /// Why a move stopped, as the toast and the CLI say it.
    struct Failure: Error {
        let message: String
        /// The move may still finish: the toast offers Retry.
        var retries = false
    }

    /// The tab menu's rows to hide: Move to Cloud unless the tab is a chat
    /// that does not already run on another machine.
    static func hiddenMenuItems(_ tab: TabModel?) -> Set<ActionID> {
        guard let record = tab?.agentSession, !record.host.hasPrefix(MachineRegistry.registryHostPrefix) else { return [action] }
        return []
    }

    /// Starts the move of the invocation's chat tab. Throws, before anything
    /// moves, when the tab is not a chat of this Mac with a session.
    func start(_ invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (tab, pane) = context.daemonTab(invocation) else { return }
        guard let record = tab.agentSession else { throw ActionFailure(message: CloudMoveStrings.notAChat) }
        let tabs = services.agentTabs
        guard services.machines.daemon(forTab: tab).isLocal, record.host != tabs.chiefHost,
              !record.host.hasPrefix(MachineRegistry.registryHostPrefix) else {
            throw ActionFailure(message: CloudMoveStrings.alreadyRemote)
        }
        guard let session = tabs.sessions[tabs.resolve(tab.id)] ?? record.session else { throw ActionFailure(message: CloudMoveStrings.noSession) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let toastID = "cloud-move-" + tab.id
        let tabID = tab.id
        let arguments = invocation.arguments
        let registry = services.registry
        let retry: @MainActor () -> Void = {
            _ = registry.perform(Self.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabID), arguments: arguments))
        }
        toast(toastID, CloudMoveStrings.moving, duration: .seconds(600))
        let work: ActionWork = Task { @MainActor in
            do {
                let machine = try await run(tab: tab, in: pane, record: record, session: session, cli: CloudMoveCLI(binary: binary),
                                            invocation: invocation)
                toast(toastID, CloudMoveStrings.moved(machine), duration: .seconds(6))
                return nil
            } catch {
                let failure = (error as? Failure) ?? Failure(message: (error as? ActionFailure)?.message ?? CloudMoveStrings.moveFailed(String(describing: error)))
                services.cloud.logger.error("cloud move failed: \(failure.message, privacy: .public)")
                toast(toastID, failure.message, duration: .seconds(failure.retries ? 60 : 12), retry: failure.retries ? retry : nil)
                return ActionWorkFailure(failure.message)
            }
        }
        registry.track(work)
    }

    /// The move, after the synchronous checks. Returns the machine's name.
    private func run(tab: TabModel, in pane: PaneModel, record: AgentSessionRef, session: String, cli: CloudMoveCLI,
                     invocation: ActionInvocation) async throws -> String {
        let workspace = services.machines.local.store.workspace(containing: pane.handle)
        guard let chat = await chatFolder(tab: tab, workspace: workspace, session: session, invocation: invocation) else { throw Failure(message: CloudMoveStrings.noFolder) }
        let folder = CloudMoveFolder(chat: chat)
        guard !folder.isTooBroad else { throw Failure(message: CloudMoveStrings.homeFolder) }
        let machine = try await self.machine(invocation)
        let name = machine.machine.title
        guard let machineSocket = await machine.daemon.connection?.endpoint?.socketPath,
              let localSocket = await services.daemon.connection?.endpoint?.socketPath else {
            throw Failure(message: CloudMoveStrings.notConnected(name), retries: true)
        }
        let remote = try await sync(folder, to: machineSocket, machine: name, cli: cli)
        let moved = try await cli.agentMove(from: localSocket, surface: tab.surface.rawValue, to: machineSocket, cwd: remote.chat)
        guard moved.ok, let movedSession = moved.sessionID else { throw Self.failure(moving: moved, machine: name) }
        do {
            try await show(movedSession, harness: record.harness, on: machine, in: remote.chat,
                           name: workspace?.name, key: moved.transferID ?? movedSession)
        } catch {
            throw Failure(message: CloudMoveStrings.tabFailed(name, String(describing: error)))
        }
        // The chat closed here with the move: its tab goes, and Reopen Closed never offers it.
        do {
            try await services.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
        } catch {
            services.cloud.logger.error("cloud move: closing the moved tab failed: \(String(describing: error), privacy: .public)")
        }
        return name
    }

    /// Syncs `folder` under the first of the machine's work roots it can write.
    private func sync(_ folder: CloudMoveFolder, to socket: String, machine: String, cli: CloudMoveCLI) async throws -> (folder: String, chat: String) {
        var last = CloudMoveCLI.Answer(ok: false)
        for root in services.cloud.move.workRoots {
            let remote = folder.remote(under: root)
            last = try await cli.syncPush(socket: socket, local: folder.root, remote: remote.folder)
            if last.ok { return remote }
            // Not this machine's home (an image without the work user): the next root.
            guard last.errorCode == "fs.permission_denied" else { break }
        }
        throw Failure(message: CloudMoveStrings.syncFailed(machine, last.error ?? last.errorCode ?? ""), retries: true)
    }

    /// The chat's folder on this Mac: the `path` argument, the tab's folder,
    /// the chat's session folder, else a folder of its workspace.
    private func chatFolder(tab: TabModel, workspace: WorkspaceModel?, session: String, invocation: ActionInvocation) async -> String? {
        if let path = invocation["path"]?.stringValue, path.hasPrefix("/") { return path }
        if let cwd = tab.cwd, cwd.hasPrefix("/") { return cwd }
        let host = services.agentTabs.localSessionHost ?? services.agentTabs.host
        if let folder = try? await host.sessionFolder(sessionId: session), folder.isLocal, folder.cwd.hasPrefix("/") { return folder.cwd }
        return workspace?.screens.flatMap(\.panes).flatMap(\.tabs).lazy.compactMap(\.cwd).first { $0.hasPrefix("/") }
    }

    /// The machine the chat moves to, connected.
    private func machine(_ invocation: ActionInvocation) async throws -> CloudMachineSession {
        let machines = services.machines
        let named = invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue
        if let named {
            let id = named.hasPrefix("machine:") ? String(named.dropFirst("machine:".count)) : named
            guard let session = machines.session(id) else { throw Failure(message: CloudMoveStrings.noSuchMachine(id)) }
            return try await connected(session, invocation)
        }
        if let live = machines.cloud.first(where: { $0.daemon.connection != nil }) ?? machines.cloud.first {
            return try await connected(live, invocation)
        }
        let created = try await services.cloud.createMachine(name: nil, startedByPerson: invocation.origin == .user)
        return try await connected(created, invocation)
    }

    private func connected(_ session: CloudMachineSession, _ invocation: ActionInvocation) async throws -> CloudMachineSession {
        // The app server link's socket serves one connection, the app's own: the CLIs need another.
        guard session.appLink == nil else { throw Failure(message: CloudMoveStrings.linkUnsupported(session.machine.title)) }
        if session.daemon.connection == nil { session.connect(origin: CloudHandlers.connectOrigin(for: invocation)) }
        let daemon = session.daemon
        guard await Self.holds(within: .seconds(180), until: { daemon.connection != nil && AgentTabStore.registryHost(of: daemon) != nil }) else {
            throw Failure(message: CloudMoveStrings.notConnected(session.machine.title), retries: true)
        }
        return session
    }

    /// Shows the moved chat on `machine`: a new Cloud workspace with a terminal
    /// in `folder`, then the chat's tab bound to `session` through the
    /// machine's store, selected; filed into the window, and shown when the run
    /// may change the view. `key` makes the chat tab's creation idempotent.
    private func show(_ session: String, harness: String?, on machine: CloudMachineSession, in folder: String, name: String?, key: String) async throws {
        let daemon = machine.daemon
        guard let connection = daemon.connection, let host = AgentTabStore.registryHost(of: daemon) else { throw DaemonError.notConnected }
        let record = AgentSessionRef(host: host, hostName: machine.machine.title, session: session, harness: harness)
        let workspace = WorkspaceKey.generate()
        let created = try await WorkspaceCreation.createWithFirstTab(workspace, name: name, on: connection, repair: machine.emptyWorkspaces) { result in
            try await connection.createTerminal(in: result.key, cwd: folder)
            return try await connection.request(NewConversationTabRequest(agentSession: record, workspace: result.workspace,
                                                                          origin: AgentTabStore.createOrigin, mutationID: "cloud-move-" + key))
        }
        services.windows.reveal(workspaceID: workspace.rawValue)
        let tab = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        if let pane = await AgentSessionWorkspace.mirroredPane(of: workspace, in: daemon.store) {
            for window in services.windows.controllers { window.state.selection.select(tab, in: pane.id) }
        }
    }

    /// The failure of a `cmux link agent move` answer, in plain words.
    static func failure(moving answer: CloudMoveCLI.Answer, machine: String) -> Failure {
        switch answer.errorCode {
        case "move_unresolved": Failure(message: CloudMoveStrings.unresolved, retries: true)
        case "move_in_progress": Failure(message: CloudMoveStrings.inProgress, retries: true)
        case "agent_session.team_vm_blocked": Failure(message: CloudMoveStrings.teamMachine(machine))
        case "agent_session.host_unverified": Failure(message: CloudMoveStrings.unknownMachine(machine))
        case "source_unreachable", "target_unreachable": Failure(message: CloudMoveStrings.unreachable(machine), retries: true)
        default: Failure(message: CloudMoveStrings.moveFailed(answer.error ?? answer.errorCode ?? ""))
        }
    }

    private func toast(_ id: String, _ message: String, duration: Duration, retry: (@MainActor () -> Void)? = nil) {
        guard let window = services.windows.active?.window ?? NSApp.mainWindow else { return }
        let action = retry == nil ? nil : CmuxToast.Action(title: CloudMoveStrings.retry)
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: id, message: message, action: action, duration: duration), in: window)
        handle.onAction = { retry?() }
    }

    /// Whether `condition` holds within `limit`: an observation, bounded by a one-shot deadline.
    private static func holds(within limit: Duration, until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a machine link's start
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await observe(condition) }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine link to come up
                try? await Task.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    private static func observe(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for await ready in ObservationStream({ condition() }) where ready { return true }
        return false
    }
}
