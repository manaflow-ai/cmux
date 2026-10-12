import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Bring Back Local (cmuxterm-hq#1874 slice 4): the one action behind the palette's "Bring Back
/// Local", the Cloud chat tab and chat page right-click menus and `cmux cloud bring-back`; the
/// reverse of ``CloudMove``. For a chat a move took from this Mac (``CloudMovedChats``) it merges
/// the machine's folder back into the chat's folder here (`cmux link sync pull`, a three-way merge
/// against what the move pushed), moves the chat from the machine's tab to this Mac in that folder
/// (`cmux link agent move`; this Mac's daemon takes it under its own guard, never with a VM's
/// control), and opens it here: a workspace whose terminal runs in the folder and whose chat tab
/// is bound to the session on this Mac. The machine's tab, whose chat closed, closes only then.
///
/// It keeps the move's recovery model: it runs on the machine the chat moved to; a conflict stops
/// before anything moves and names the files; a run that may not have finished (a thrown CLI, an
/// unresolved move) retries on that machine (a second pull finds nothing new, a rerun of the move
/// resolves an unresolved one first); after the move committed Retry only opens the local tab, and
/// the ledger keeps that until the tab opened, so the row and a relaunch still only open it.
/// Progress and failures are toasts, never a sheet.
@MainActor
struct CloudBringBack {
    static let action: ActionID = "cloudBringBack"
    typealias Failure = CloudMove.Failure
    let services: AppServices

    /// The tab and chat menus' rows to hide: Bring Back Local unless the chat runs on a machine
    /// that a move from this Mac put it on.
    static func hiddenMenuItems(_ record: AgentSessionRef?, movedChats: CloudMovedChats?) -> Set<ActionID> {
        guard let record, record.host.hasPrefix(MachineRegistry.registryHostPrefix), let session = record.session,
              movedChats?.entry(host: record.host, session: session) != nil else { return [action] }
        return []
    }

    /// Starts bringing back the invocation's machine chat tab. Throws, before anything moves,
    /// when the tab is not a chat a move from this Mac put on a machine.
    func start(_ invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (tab, _) = context.daemonTab(invocation) else { return }
        if case .show(let shown) = services.cloud.bringBackRetries[tab.id] {
            return perform(tab: tab) { try await reshow(shown, tab: tab) }
        }
        guard let record = tab.agentSession, record.host.hasPrefix(MachineRegistry.registryHostPrefix),
              let session = record.session ?? services.agentTabs.sessions[services.agentTabs.resolve(tab.id)],
              let entry = services.cloud.movedChats.entry(host: record.host, session: session) else {
            throw ActionFailure(message: CloudBringBackStrings.notFromMove)
        }
        // The move back committed before (this run or one before a relaunch): only open the tab.
        if let back = entry.broughtBack {
            return perform(tab: tab) { try await reshow(Self.shown(entry, back), tab: tab) }
        }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        perform(tab: tab) { try await run(tab: tab, entry: entry, cli: cli) }
    }

    /// Runs `body` (which returns the machine's name) behind the toasts. A stop records its retry
    /// for `tab` and offers it; success clears it.
    private func perform(tab: TabModel, _ body: @escaping @MainActor () async throws -> String) {
        let toastID = "cloud-bring-back-" + tab.id
        let tabID = tab.id
        let retries = services.cloud.bringBackRetries
        CloudMove.toast(services, toastID, CloudBringBackStrings.bringing, duration: .seconds(600))
        let work: ActionWork = Task { @MainActor in
            do {
                _ = try await body()
                retries[tabID] = nil
                CloudMove.toast(services, toastID, CloudBringBackStrings.broughtBack, duration: .seconds(6))
                return nil
            } catch {
                return stopped(error, tab: tabID, toast: toastID)
            }
        }
        services.registry.track(work)
    }

    /// A stop: records what Retry does for machine tab `tabID` and offers it on the toast. Any
    /// error that names no Retry keeps the one a stop saved before (cx-rppd.8).
    private func stopped(_ error: any Error, tab tabID: String, toast toastID: String) -> ActionWorkFailure {
        let retries = services.cloud.bringBackRetries
        let failure = (error as? Failure) ?? Failure(message: (error as? ActionFailure)?.message ?? CloudBringBackStrings.failed(String(describing: error)),
                                                     retry: retries[tabID])
        services.cloud.logger.error("cloud bring back failed: \(failure.message, privacy: .public)")
        retries[tabID] = failure.retry
        var retry: (@MainActor () -> Void)?
        if failure.retry != nil {
            let registry = services.registry
            let again = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabID), arguments: [:], origin: .user)
            retry = { _ = registry.perform(Self.action, invocation: again) }
        }
        CloudMove.toast(services, toastID, failure.message, duration: .seconds(retry == nil ? 12 : 60), retry: retry)
        return ActionWorkFailure(failure.message)
    }

    /// The bring back, after the synchronous checks. Returns the machine's name.
    private func run(tab: TabModel, entry: CloudMovedChats.Entry, cli: CloudMoveCLI) async throws -> String {
        let again = CloudMoveRetries.Retry.move(machineID: entry.machineID)
        guard let machine = services.machines.session(entry.machineID) else {
            throw Failure(message: CloudMoveStrings.noSuchMachine(entry.machineID), retry: again)
        }
        let name = machine.machine.title
        guard FileManager.default.fileExists(atPath: entry.localRoot) else { throw Failure(message: CloudBringBackStrings.noFolder(entry.localRoot)) }
        guard let machineSocket = await machine.daemon.connection?.endpoint?.socketPath,
              let localSocket = await services.daemon.connection?.endpoint?.socketPath else {
            throw Failure(message: CloudMoveStrings.notConnected(name), retry: again)
        }
        let pulled: CloudMoveCLI.Answer
        do {
            pulled = try await cli.syncPull(socket: machineSocket, local: entry.localRoot, remote: entry.remoteFolder)
        } catch {
            // Timed out or didn't launch: nothing moved, so Retry runs it again on this machine.
            throw Failure(message: CloudBringBackStrings.syncFailed(name, String(describing: error)), retry: again)
        }
        guard pulled.ok else {
            // A conflict changed nothing here: the chat stays on the machine until the files are settled.
            if pulled.errorCode == "sync_conflict" { throw Failure(message: CloudBringBackStrings.conflict(pulled.conflicts), retry: again) }
            throw Failure(message: CloudBringBackStrings.syncFailed(name, pulled.error ?? pulled.errorCode ?? ""), retry: again)
        }
        let moved: CloudMoveCLI.Answer
        do {
            moved = try await cli.agentMove(from: machineSocket, surface: tab.surface.rawValue, to: localSocket, cwd: entry.localChat)
        } catch {
            services.cloud.logger.error("cloud bring back: link agent move: \(String(describing: error), privacy: .public)")
            throw Failure(message: CloudBringBackStrings.unresolved, retry: again)
        }
        guard moved.ok, let session = moved.sessionID else { throw Self.failure(moving: moved, machine: name, retry: again) }
        // The move committed: from here Retry only opens the chat's tab on this Mac. The ledger
        // keeps that (not only memory) until the tab opened.
        let back = CloudMovedChats.BroughtBack(session: session, key: moved.transferID ?? session)
        var committed = entry
        committed.broughtBack = back
        services.cloud.movedChats.record(committed)
        try await finish(Self.shown(committed, back), tab: tab)
        return name
    }

    /// What opens a chat moved back by `back`, from its ledger entry.
    private static func shown(_ entry: CloudMovedChats.Entry, _ back: CloudMovedChats.BroughtBack) -> CloudMoveRetries.Shown {
        CloudMoveRetries.Shown(session: back.session, harness: entry.harness, machineID: entry.machineID, folder: entry.localChat,
                               name: entry.name, key: back.key, host: entry.host, movedSession: entry.session)
    }

    /// A Retry of a bring back that committed: opens the chat's tab here, nothing else.
    private func reshow(_ shown: CloudMoveRetries.Shown, tab: TabModel) async throws -> String {
        try await finish(shown, tab: tab)
        return services.machines.machineName(shown.machineID) ?? shown.machineID
    }

    /// Opens the chat's tab on this Mac, then closes the machine's tab, whose chat closed with the move.
    private func finish(_ shown: CloudMoveRetries.Shown, tab: TabModel) async throws {
        do {
            try await show(shown)
        } catch {
            throw Failure(message: CloudBringBackStrings.tabFailed(String(describing: error)), retry: .show(shown))
        }
        if let host = shown.host, let moved = shown.movedSession { services.cloud.movedChats.forget(host: host, session: moved) }
        // Reopen Closed never offers it.
        do {
            let daemon = services.machines.daemon(forTab: tab)
            if !daemon.isLocal { try await daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd) }
        } catch {
            services.cloud.logger.error("cloud bring back: closing the machine's tab failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Shows the chat on this Mac: a new workspace with a terminal in its folder, then its tab bound
    /// to `shown.session` on this Mac, selected. `shown.key` makes the tab's creation idempotent.
    private func show(_ shown: CloudMoveRetries.Shown) async throws {
        let daemon = services.daemon, tabs = services.agentTabs
        guard let connection = daemon.connection, let host = tabs.localHost else { throw DaemonError.notConnected }
        let record = AgentSessionRef(host: host, hostName: tabs.localHostName, session: shown.session, harness: shown.harness)
        let workspace = WorkspaceKey.generate()
        let created = try await WorkspaceCreation.createWithFirstTab(workspace, name: shown.name, on: connection, repair: services.emptyWorkspaces) { result in
            try await connection.createTerminal(in: result.key, cwd: shown.folder)
            return try await connection.request(NewConversationTabRequest(agentSession: record, workspace: result.workspace,
                                                                          origin: AgentTabStore.createOrigin, mutationID: "cloud-bring-back-" + shown.key))
        }
        services.windows.reveal(workspaceID: workspace.rawValue)
        let tab = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        if let pane = await AgentSessionWorkspace.mirroredPane(of: workspace, in: daemon.store) {
            for window in services.windows.controllers { window.state.selection.select(tab, in: pane.id) }
        }
    }

    /// The failure of a `cmux link agent move` answer, in plain words. This Mac's guard refuses a
    /// chat that approves on its own (`transfer.policy`), runs in a mode that doesn't ask
    /// (`transfer.mode`), or runs an agent it can't guard (`transfer.family`); the chat stays on
    /// the machine, unchanged, and the first two can Retry once the chat asks.
    static func failure(moving answer: CloudMoveCLI.Answer, machine: String, retry: CloudMoveRetries.Retry) -> Failure {
        let detail = answer.error ?? ""
        if detail.contains("transfer.policy") { return Failure(message: CloudBringBackStrings.policyBlocks, retry: retry) }
        if detail.contains("transfer.mode") { return Failure(message: CloudBringBackStrings.modeBlocks, retry: retry) }
        if detail.contains("transfer.family") { return Failure(message: CloudBringBackStrings.familyBlocks) }
        switch answer.errorCode {
        case "move_unresolved", CloudMoveCLI.badAnswer: return Failure(message: CloudBringBackStrings.unresolved, retry: retry)
        case "move_in_progress": return Failure(message: CloudMoveStrings.inProgress, retry: retry)
        case "source_unreachable", "target_unreachable": return Failure(message: CloudMoveStrings.unreachable(machine), retry: retry)
        default: return Failure(message: CloudBringBackStrings.failed(answer.error ?? answer.errorCode ?? ""))
        }
    }
}
