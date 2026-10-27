import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
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
/// Progress and failures are toasts on the window, never a sheet. A stopped
/// move leaves this Mac's tab and a retry (``CloudMoveRetries``), which the
/// toast's Retry and running the action again on that tab both use. A move
/// that may not have finished runs again on the same machine (a second sync
/// writes only changes, and a rerun of the move resolves an unresolved one
/// first). A move that committed only opens its tab on the machine, never
/// syncs or moves again. Bring Back Local is the reverse (``CloudBringBack``);
/// a committed move is recorded for it (``CloudMovedChats``).
@MainActor
struct CloudMove {
    static let action: ActionID = "cloudMove"
    let services: AppServices

    /// Why a move stopped, as the toast and the CLI say it.
    struct Failure: Error {
        let message: String
        /// What Retry does; none when retrying can't help.
        var retry: CloudMoveRetries.Retry?
    }

    /// The tab and chat menus' Cloud rows to hide: Move to Cloud unless the tab is a chat that
    /// does not already run on another machine, and Bring Back Local unless a move from this Mac
    /// put it there (``CloudBringBack/hiddenMenuItems(_:movedChats:)``).
    static func hiddenMenuItems(_ tab: TabModel?) -> Set<ActionID> { hiddenMenuItems(tab?.agentSession) }

    static func hiddenMenuItems(_ record: AgentSessionRef?) -> Set<ActionID> {
        let back = CloudBringBack.hiddenMenuItems(record, movedChats: CloudMovedChats.app)
        guard let record, !record.host.hasPrefix(MachineRegistry.registryHostPrefix) else { return back.union([action]) }
        return back
    }

    /// Starts the move of the invocation's chat tab. Throws, before anything
    /// moves, when the tab is not a chat of this Mac with a session.
    func start(_ invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (tab, pane) = context.daemonTab(invocation) else { return }
        let retries = services.cloud.moveRetries
        var left = retries[tab.id]
        // Kept across launches: a pin to a machine that no longer exists would refuse every move of
        // this tab, so it goes, and so does a retry kept for a tab that is no chat.
        if case .move(let machineID) = left, services.cloud.hasLoadedMachines, services.machines.session(machineID) == nil { left = nil }
        if tab.agentSession == nil { left = nil }
        if left != retries[tab.id] { retries[tab.id] = left }
        if case .show(let shown) = left { return perform(tab: tab, invocation: invocation) { try await reshow(shown, tab: tab, invocation: invocation) } }
        guard let record = tab.agentSession else { throw ActionFailure(message: CloudMoveStrings.notAChat) }
        let tabs = services.agentTabs
        guard services.machines.daemon(forTab: tab).isLocal, !record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix),
              !record.host.hasPrefix(MachineRegistry.registryHostPrefix) else {
            throw ActionFailure(message: CloudMoveStrings.alreadyRemote)
        }
        guard let session = tabs.sessions[tabs.resolve(tab.id)] ?? record.session else { throw ActionFailure(message: CloudMoveStrings.noSession) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        var invocation = invocation
        // An unresolved move finishes on the machine it started on.
        if let machineID = left?.machineID, invocation["machine"] == nil { invocation.arguments["machine"] = .string(machineID) }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        perform(tab: tab, invocation: invocation) { [invocation] in
            try await run(tab: tab, in: pane, record: record, session: session, cli: cli, invocation: invocation)
        }
    }

    /// Runs `body` (which returns the machine's name) behind the toasts. A stop
    /// records its retry for `tab` and offers it; success clears it.
    private func perform(tab: TabModel, invocation: ActionInvocation, _ body: @escaping @MainActor () async throws -> String) {
        let toastID = "cloud-move-" + tab.id
        let tabID = tab.id
        let retries = services.cloud.moveRetries
        toast(toastID, CloudMoveStrings.moving, duration: .seconds(600))
        // An agent's ask in the chat shows the move too (``CloudMoveAsks``).
        let asks = services.cloud.moveAsks
        asks.moveStarted(tabID, services: services)
        let work: ActionWork = Task { @MainActor in
            do {
                let machine = try await body()
                retries[tabID] = nil
                toast(toastID, CloudMoveStrings.moved(machine), duration: .seconds(6))
                asks.moveEnded(tabID, failure: nil, services: services)
                return nil
            } catch {
                let failure = stopped(error, tab: tabID, toast: toastID, invocation: invocation)
                asks.moveEnded(tabID, failure: failure.message, services: services)
                return failure
            }
        }
        services.registry.track(work)
    }

    /// A stop: records what Retry does for tab `tabID` and offers it on the toast.
    private func stopped(_ error: any Error, tab tabID: String, toast toastID: String, invocation: ActionInvocation) -> ActionWorkFailure {
        // Any other error keeps the Retry a stop saved before (a move pinned to its machine).
        let failure = (error as? Failure) ?? Failure(message: (error as? ActionFailure)?.message ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error)),
                                                     retry: services.cloud.moveRetries[tabID])
        services.cloud.logger.error("cloud move failed: \(failure.message, privacy: .public)")
        services.cloud.moveRetries[tabID] = failure.retry
        var retry: (@MainActor () -> Void)?
        if let next = failure.retry {
            var arguments = invocation.arguments
            arguments[CloudMachineUpdate.argument] = nil
            if let machineID = next.machineID { arguments["machine"] = .string(machineID) }
            if case .update = next { arguments[CloudMachineUpdate.argument] = .bool(true) }
            let registry = services.registry
            let again = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabID), arguments: arguments, origin: .user)
            retry = { _ = registry.perform(Self.action, invocation: again) }
        }
        var title = CloudMoveStrings.retry
        if case .update = failure.retry { title = CloudMachineUpdateStrings.button }
        Self.toast(services, toastID, failure.message, duration: .seconds(retry == nil ? 12 : 60), retry: retry, retryTitle: title)
        return ActionWorkFailure(failure.message)
    }

    /// The move, after the synchronous checks. Returns the machine's name.
    private func run(tab: TabModel, in pane: PaneModel, record: AgentSessionRef, session: String, cli: CloudMoveCLI,
                     invocation: ActionInvocation) async throws -> String {
        let workspace = services.machines.local.store.workspace(containing: pane.handle)
        guard let chat = try await chatFolder(tab: tab, workspace: workspace, session: session, invocation: invocation),
              let folder = CloudMoveFolder(chat: chat) else { throw Failure(message: CloudMoveStrings.noFolder) }
        guard !folder.isTooBroad else { throw Failure(message: CloudMoveStrings.homeFolder) }
        let machine = try await self.machine(invocation)
        let name = machine.machine.title, again = CloudMoveRetries.Retry.move(machineID: machine.machineID)
        // From here the chat may move to this machine: a quit or a crash before the move ends
        // leaves Retry pinned to it, and the relaunched app finishes the move there.
        services.cloud.moveRetries[tab.id] = again
        guard let machineSocket = await machine.daemon.connection?.endpoint?.socketPath,
              let localSocket = await services.daemon.connection?.endpoint?.socketPath else {
            throw Failure(message: CloudMoveStrings.notConnected(name), retry: again)
        }
        // Only the person's "Update Machine" updates the machine first.
        if CloudMachineUpdate.requested(invocation) {
            try await CloudMachineUpdate.run(services, name: name, socket: machineSocket, cli: cli, toast: "cloud-move-" + tab.id,
                                             retry: .update(machineID: machine.machineID))
            toast("cloud-move-" + tab.id, CloudMoveStrings.moving, duration: .seconds(600))
        }
        let remote = try await sync(folder, to: machineSocket, machine: name, cli: cli, retry: again)
        let moved: CloudMoveCLI.Answer
        do {
            moved = try await cli.agentMove(from: localSocket, surface: tab.surface.rawValue, to: machineSocket, cwd: remote.chat)
        } catch {
            // Timed out or didn't run to its answer: the move may have committed, and a rerun resolves it.
            services.cloud.logger.error("cloud move: link agent move: \(String(describing: error), privacy: .public)")
            throw Failure(message: CloudMoveStrings.unresolved, retry: again)
        }
        guard moved.ok, let movedSession = moved.sessionID else { throw Self.failure(moving: moved, machine: name, retry: again) }
        // Bring Back Local merges into this folder, and offers itself only for chats recorded here.
        if let host = AgentTabStore.registryHost(of: machine.daemon) {
            let local = folder.subpath.isEmpty ? folder.root : folder.root + "/" + folder.subpath
            services.cloud.movedChats.record(CloudMovedChats.Entry(machineID: machine.machineID, host: host, session: movedSession, harness: record.harness,
                                                                   localRoot: folder.root, localChat: local, remoteFolder: remote.folder,
                                                                   remoteChat: remote.chat, name: workspace?.name))
            services.cloud.accessAsks.start(services: services)
        }
        // The move committed: from here Retry only opens the chat's tab on the machine.
        let shown = CloudMoveRetries.Shown(session: movedSession, harness: record.harness, machineID: machine.machineID, folder: remote.chat,
                                           name: workspace?.name, key: moved.transferID ?? movedSession)
        // A quit or a crash before the tab opens leaves the relaunched app only opening it.
        services.cloud.moveRetries[tab.id] = .show(shown)
        try await finish(shown, on: machine, tab: tab)
        return name
    }

    /// A Retry of a move that committed: opens the chat's tab on its machine, nothing else.
    private func reshow(_ shown: CloudMoveRetries.Shown, tab: TabModel, invocation: ActionInvocation) async throws -> String {
        let retry = CloudMoveRetries.Retry.show(shown)
        guard let session = services.machines.session(shown.machineID) else {
            throw Failure(message: CloudMoveStrings.noSuchMachine(shown.machineID), retry: retry)
        }
        let machine: CloudMachineSession
        do {
            machine = try await connected(session, invocation)
        } catch let failure as Failure {
            throw Failure(message: failure.message, retry: retry)
        }
        try await finish(shown, on: machine, tab: tab)
        return machine.machine.title
    }

    /// Opens the moved chat's tab on `machine`, then closes this Mac's tab, whose chat closed with the move.
    private func finish(_ shown: CloudMoveRetries.Shown, on machine: CloudMachineSession, tab: TabModel) async throws {
        do {
            try await show(shown.session, harness: shown.harness, on: machine, in: shown.folder, name: shown.name, key: shown.key)
        } catch {
            throw Failure(message: CloudMoveStrings.tabFailed(machine.machine.title, CloudStrings.errorText(error)), retry: .show(shown))
        }
        // Reopen Closed never offers it.
        do {
            try await services.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
        } catch {
            services.cloud.logger.error("cloud move: closing the moved tab failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Syncs `folder` under the first of the machine's work roots it can write.
    private func sync(_ folder: CloudMoveFolder, to socket: String, machine: String, cli: CloudMoveCLI,
                      retry: CloudMoveRetries.Retry) async throws -> (folder: String, chat: String) {
        var last = CloudMoveCLI.Answer(ok: false)
        for root in services.cloud.move.workRoots {
            let remote = folder.remote(under: root)
            do {
                last = try await cli.syncPush(socket: socket, local: folder.root, remote: remote.folder)
            } catch {
                // Timed out or didn't launch: nothing moved yet, so Retry runs the move again on this machine.
                throw Failure(message: CloudMoveStrings.syncFailed(machine, CloudStrings.errorText(error)), retry: retry)
            }
            if last.ok { return remote }
            // Not this machine's home (an image without the work user): the next root.
            guard last.errorCode == "fs.permission_denied" else { break }
        }
        if last.errorCode == CloudMoveStrings.outdatedCode { throw Failure(message: CloudMoveStrings.outdatedMachine(machine), retry: retry.updating) }
        throw Failure(message: CloudMoveStrings.syncFailed(machine, last.error ?? last.errorCode ?? ""), retry: retry)
    }

    /// The chat's folder on this Mac: the `path` argument (the CLI makes a
    /// relative one absolute in the caller's folder), the chat's own folder
    /// (its tab's, else its session's), else a chat's folder in its workspace,
    /// else a terminal's there.
    func chatFolder(tab: TabModel, workspace: WorkspaceModel?, session: String, invocation: ActionInvocation) async throws -> String? {
        if let path = invocation["path"]?.stringValue, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw Failure(message: CloudMoveStrings.relativePath(path)) }
            return expanded
        }
        if let cwd = tab.cwd, cwd.hasPrefix("/") { return cwd }
        let host = services.agentTabs.localSessionHost ?? services.agentTabs.host
        if let folder = try? await host.sessionFolder(sessionId: session), folder.isLocal, folder.cwd.hasPrefix("/") { return folder.cwd }
        let tabs = workspace?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
        let chats = tabs.filter { $0.agentSession != nil }
        return (chats + tabs).lazy.compactMap(\.cwd).first { $0.hasPrefix("/") }
    }

    /// The machine the chat moves to, connected.
    private func machine(_ invocation: ActionInvocation) async throws -> CloudMachineSession {
        let machines = services.machines
        let named = invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue
        if let named {
            let id = named.hasPrefix("machine:") ? String(named.dropFirst("machine:".count)) : named
            guard let session = machines.session(id) else { throw Failure(message: CloudMoveStrings.noSuchMachine(id), retry: .move(machineID: id)) }
            return try await connected(session, invocation)
        }
        if let live = machines.cloud.first(where: { $0.daemon.connection != nil }) ?? machines.cloud.first {
            return try await connected(live, invocation)
        }
        let created = try await services.cloud.createMachine(name: nil, startedByPerson: invocation.origin == .user, askedBy: invocation.callerAgentSession)
        return try await connected(created, invocation)
    }

    private func connected(_ session: CloudMachineSession, _ invocation: ActionInvocation) async throws -> CloudMachineSession {
        // The app server link's socket serves one connection, the app's own: the CLIs need another.
        guard session.appLink == nil else { throw Failure(message: CloudMoveStrings.linkUnsupported(session.machine.title)) }
        // A paused machine (idle auto-pause) resumes on this attach; a live one connects. A
        // record that may be stale (paused behind the app) is read again first.
        if session.daemon.connection == nil {
            await session.refreshIfMaybePaused()
            if session.machine.status == .paused { session.attach(origin: CloudHandlers.connectOrigin(for: invocation)) } else { session.connect(origin: CloudHandlers.connectOrigin(for: invocation)) }
        }
        let daemon = session.daemon
        // A failed resume ends the wait at once, with its reason.
        guard await Self.holds(within: .seconds(180), until: {
            session.resumeFailure != nil || (daemon.connection != nil && AgentTabStore.registryHost(of: daemon) != nil)
        }) else {
            throw Failure(message: CloudMoveStrings.notConnected(session.machine.title), retry: .move(machineID: session.machineID))
        }
        if let failure = session.resumeFailure { throw Failure(message: failure, retry: .move(machineID: session.machineID)) }
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
        if let pane = await daemon.store.firstPane(mirroring: workspace) {
            for window in services.windows.controllers { window.state.selection.select(tab, in: pane.id) }
        }
    }

    /// The failure of a `cmux link agent move` answer, in plain words. `retry`
    /// runs the move again on its machine; a garbage answer (a crash) may come
    /// after the commit, so it is unresolved, never failed.
    static func failure(moving answer: CloudMoveCLI.Answer, machine: String, retry: CloudMoveRetries.Retry) -> Failure {
        switch answer.errorCode {
        case "move_unresolved", CloudMoveCLI.badAnswer: Failure(message: CloudMoveStrings.unresolved, retry: retry)
        case "move_in_progress": Failure(message: CloudMoveStrings.inProgress, retry: retry)
        case "agent_session.team_vm_blocked": Failure(message: CloudMoveStrings.teamMachine(machine))
        case "agent_session.host_unverified": Failure(message: CloudMoveStrings.unknownMachine(machine))
        // This Mac's own daemon (the source) is never the machine to update.
        case CloudMoveStrings.outdatedCode where answer.side != "source":
            Failure(message: CloudMoveStrings.outdatedMachine(machine), retry: retry.updating)
        case "source_unreachable", "target_unreachable": Failure(message: CloudMoveStrings.unreachable(machine), retry: retry)
        default: Failure(message: CloudMoveStrings.moveFailed(answer.error ?? answer.errorCode ?? ""))
        }
    }

    private func toast(_ id: String, _ message: String, duration: Duration, retry: (@MainActor () -> Void)? = nil) {
        Self.toast(services, id, message, duration: duration, retry: retry)
    }

    /// A toast on the active window, with Retry when `retry` is set (Bring Back Local's too).
    static func toast(_ services: AppServices, _ id: String, _ message: String, duration: Duration, retry: (@MainActor () -> Void)? = nil,
                      retryTitle: String = CloudMoveStrings.retry) {
        guard let window = services.windows.active?.window ?? NSApp.mainWindow else { return }
        let action = retry == nil ? nil : CmuxToast.Action(title: retryTitle)
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: id, message: message, action: action, duration: duration), in: window)
        handle.onAction = { retry?() }
    }

    /// Whether `condition` holds within `limit`: an observation, bounded by a one-shot deadline.
    static func holds(within limit: Duration, until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
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
