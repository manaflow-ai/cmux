import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import Foundation

/// Bring Back Local (cmuxterm-hq#1874 slice 4): the one action behind the palette's "Bring Back
/// Local", the Cloud chat tab and chat page right-click menus and `cmux cloud bring-back`; the
/// reverse of ``CloudMove``. For a chat a move took from this Mac (``CloudMovedChats``) it merges
/// the machine's folder back into the chat's folder here (`cmux link seed pull --or-copy`: a seeded
/// git project as the seed's diff, a copied folder as `cmux link sync pull`'s three-way merge
/// against what the move pushed; the CLI picks), moves the chat from the machine's tab to this Mac in that folder
/// (`cmux link agent move`; this Mac's daemon takes it under its own guard, never with a VM's
/// control), and opens it here: a workspace whose terminal runs in the folder and whose chat tab
/// is bound to the session on this Mac. The machine's tab, whose chat closed, closes only then.
///
/// It keeps the move's recovery model: it runs on the machine the chat moved to; a conflict stops
/// before anything moves and names the files; a run that may not have finished (a thrown CLI, an
/// unresolved move) retries on that machine (a second pull finds nothing new, a rerun of the move
/// resolves an unresolved one first); after the move committed Retry only opens the local tab, and
/// the ledger keeps that until the tab opened, so the row and a relaunch still only open it.
/// When this Mac's guard refuses the chat for a policy or mode that doesn't ask, the stop's toast
/// offers "Ask first, then bring back" (cx-rppd.10): only that button runs the move again with
/// `--ask-first` (``askFirstInvocation(tab:)``), so the machine's daemon narrows the chat there to an
/// asking policy and mode before it moves; a plain rerun never changes the chat. The guard here is
/// never loosened. Progress and failures are toasts, never a sheet.
///
/// Move to Another Machine (``toMachine``) is the same run with another Cloud machine as the target
/// in place of this Mac (Leo, 2026-11-10: "a proper \"move to other cloud\""): the named one, else another
/// connected one, else any, else a new one. Its folder goes machine to machine, never through this Mac's folder
/// (Leo: "isn't this like yet another sync problem?"): one `cmux link agent move --sync relay` sends it as git
/// when a Move to Cloud seeded it from here, else copies it, then the chat lands with its last changes; its
/// ledger entry then names the new machine.
@MainActor
struct CloudBringBack {
    static let action: ActionID = "cloudBringBack"
    static let toMachine: ActionID = "cloudMoveToMachine"
    /// The invocation argument the "Ask first, then bring back" button sets.
    static let askFirstArgument = "askFirst"
    typealias Failure = CloudMove.Failure
    let services: AppServices

    /// The tab and chat menus' rows to hide: Bring Back Local unless the chat runs on a machine
    /// that a move from this Mac put it on.
    static func hiddenMenuItems(_ record: AgentSessionRef?, movedChats: CloudMovedChats?) -> Set<ActionID> {
        guard let record, record.host.hasPrefix(MachineRegistry.registryHostPrefix), let session = record.session,
              movedChats?.entry(host: record.host, session: session) != nil else { return [action, toMachine] }
        return []
    }

    /// Starts bringing back the invocation's machine chat tab. Throws, before anything moves,
    /// when the tab is not a chat a move from this Mac put on a machine.
    func start(_ invocation: ActionInvocation, context: AppActionContext, toMachine asked: Bool = false) throws {
        guard let (tab, _) = context.daemonTab(invocation) else { return }
        if !asked, case .show(let shown) = services.cloud.bringBackRetries[tab.id] {
            return perform(tab: tab, action: Self.action) { try await reshow(shown, tab: tab) }
        }
        guard let record = tab.agentSession, record.host.hasPrefix(MachineRegistry.registryHostPrefix),
              let session = record.session ?? services.agentTabs.sessions[services.agentTabs.tabKey(of: tab)],
              let entry = services.cloud.movedChats.entry(host: record.host, session: session) else {
            throw ActionFailure(message: CloudBringBackStrings.notFromMove)
        }
        // The move back committed before (this run or one before a relaunch): only open the tab.
        if let back = entry.broughtBack {
            // Brought back already: only its tab here opens, never a move on from a machine it left.
            guard !asked else { throw ActionFailure(message: CloudBringBackStrings.notFromMove) }
            return perform(tab: tab, action: Self.action) { try await reshow(entry.shown(back), tab: tab) }
        }
        // A move to another machine that may have landed there (its pin, ``run(tab:entry:cli:askFirst:update:toMachine:invocation:)``)
        // finishes first, whichever of the two ran: a bring back would drop the pin, and a later move would seed over what the
        // chat already did there. Once it lands, Bring Back Local runs from that machine's tab.
        // A pin to a machine gone from the loaded list could never finish: it goes, as Move to Cloud's own do.
        let retries = services.cloud.bringBackRetries
        if case .move(let id)? = retries[tab.id], id != entry.machineID, services.cloud.hasLoadedCurrentMachines, services.machines.session(id) == nil {
            retries[tab.id] = nil
        }
        var pinned = false
        if case .move(let id)? = retries[tab.id], id != entry.machineID { pinned = true }
        let toMachine = asked || pinned
        let action = toMachine ? Self.toMachine : Self.action
        // One run per chat at a time: a second's copy could land after the first's chat already ran there.
        guard !services.cloud.movingBack.contains(tab.id) else { throw ActionFailure(message: CloudMoveStrings.inProgress) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout, stateDirectory: services.cloud.move.stateDirectory)
        // Only the refusal toast's "Ask first, then bring back" narrows the chat on the machine.
        let askFirst = invocation[Self.askFirstArgument] == .bool(true)
        // Only the person's "Update Machine" updates the machine first (``CloudMachineUpdate``).
        let update = CloudMachineUpdate.requested(invocation)
        // The person's Bring Back updates a machine too old for it first (``CloudMove/updatingFirst(_:_:)``).
        perform(tab: tab, action: action) {
            try await CloudMove.updatingFirst(invocation) { invocation in
                try await run(tab: tab, entry: entry, cli: cli, askFirst: askFirst, update: update || CloudMachineUpdate.requested(invocation),
                              toMachine: toMachine, invocation: invocation)
            }
        }
    }

    /// Runs `body` (which returns the machine's name) behind the toasts. A stop records its retry
    /// for `tab` and offers it; success clears it.
    private func perform(tab: TabModel, action: ActionID, _ body: @escaping @MainActor () async throws -> String) {
        let toastID = "cloud-bring-back-" + tab.id
        let tabID = tab.id, toMachine = action == Self.toMachine
        let retries = services.cloud.bringBackRetries, cloud = services.cloud
        cloud.movingBack.insert(tabID)
        CloudMove.toast(services, toastID, toMachine ? CloudMoveStrings.moving : CloudBringBackStrings.bringing, duration: CloudMove.working)
        let work: ActionWork = Task { @MainActor in
            defer { cloud.movingBack.remove(tabID) }
            do {
                let machine = try await body()
                retries[tabID] = nil
                CloudMove.toast(services, toastID, toMachine ? CloudMoveStrings.moved(machine) : CloudBringBackStrings.broughtBack, duration: .seconds(6))
                return nil
            } catch {
                return stopped(error, tab: tabID, toast: toastID, action: action)
            }
        }
        services.registry.track(work)
    }

    /// A stop: records what Retry does for machine tab `tabID` and offers it on the toast. Any
    /// error that names no Retry keeps the one a stop saved before (cx-rppd.8).
    private func stopped(_ error: any Error, tab tabID: String, toast toastID: String, action: ActionID) -> ActionWorkFailure {
        let retries = services.cloud.bringBackRetries
        let failure = (error as? Failure) ?? Failure(message: (error as? ActionFailure)?.message ?? CloudBringBackStrings.failed(CloudStrings.errorText(error)),
                                                     retry: retries[tabID])
        services.cloud.logger.error("cloud bring back failed: \(failure.message, privacy: .public)")
        retries[tabID] = failure.retry
        var retry: (@MainActor () -> Void)?
        if failure.retry != nil {
            let registry = services.registry
            var again = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabID), arguments: [:], origin: .user)
            if case .askFirst = failure.retry { again = Self.askFirstInvocation(tab: tabID) }
            if case .update = failure.retry { again.arguments[CloudMachineUpdate.argument] = .bool(true) }
            retry = { _ = registry.perform(action, invocation: again) }
        }
        let title: String
        switch failure.retry {
        case .askFirst: title = CloudBringBackStrings.askFirst
        case .update: title = CloudMachineUpdateStrings.button
        default: title = CloudMoveStrings.retry
        }
        CloudMove.toast(services, toastID, failure.message, duration: .seconds(retry == nil ? 12 : 60), retry: retry, retryTitle: title)
        return ActionWorkFailure(failure.message)
    }

    /// The target folder's suffix: a folder of its own per machine and per chat, so two chats of one folder never seed over
    /// each other there. Whole ids: time-ordered ids share their first characters for hours.
    static func targetSuffix(machineID: String, session: String) -> String { "-" + machineID + "-" + session }

    /// What the refusal toast's "Ask first, then bring back" runs on machine tab `tab`.
    static func askFirstInvocation(tab: String) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), arguments: [askFirstArgument: .bool(true)], origin: .user)
    }

    /// The bring back, after the synchronous checks. Returns the machine's name (with `toMachine`, the one the
    /// chat went to). `askFirst` narrows the machine's chat to an asking policy and mode before it moves.
    private func run(tab: TabModel, entry: CloudMovedChats.Entry, cli: CloudMoveCLI, askFirst: Bool, update: Bool, toMachine: Bool,
                     invocation: ActionInvocation) async throws -> String {
        // A move to another machine that reached the transfer is pinned to that machine (its retry names it, kept across
        // launches): the rerun goes straight to the transfer, which settles a recorded one first. A pull and a full seed
        // before it could write over what the chat already did there. Every stop of the rerun keeps that pin.
        var pinned: String?
        if toMachine, case .move(let id)? = services.cloud.bringBackRetries[tab.id], id != entry.machineID { pinned = id }
        var again = CloudMoveRetries.Retry.move(machineID: pinned ?? entry.machineID)
        guard let machine = services.machines.session(entry.machineID) else {
            // Gone from the loaded machine list: deleted, so a Retry could never reach it and none is kept.
            if services.cloud.hasLoadedCurrentMachines { throw Failure(message: CloudMoveStrings.machineDeleted, retry: pinned.map { _ in again }) }
            throw Failure(message: CloudMoveStrings.noSuchMachine(entry.machineID), retry: again)
        }
        let name = machine.machine.title
        // A pin stays through every stop until its transfer is settled. A move to another machine never reads this folder.
        guard toMachine || FileManager.default.fileExists(atPath: entry.localRoot) else {
            throw Failure(message: CloudBringBackStrings.noFolder(entry.localRoot), retry: pinned.map { _ in again })
        }
        // A connect's stop names its own machine; this run's Retry (a kept pin above all) stays.
        let connected = { [again] (session: CloudMachineSession) async throws -> CloudMachineSession in
            do { return try await CloudMove.connected(session, invocation) } catch let failure as Failure { throw Failure(message: failure.message, retry: again) }
        }
        _ = try await connected(machine)
        let pending: CloudMachineSession?
        if let id = pinned {
            guard let session = services.machines.session(id) else { throw Failure(message: CloudMoveStrings.noSuchMachine(id), retry: again) }
            pending = try await connected(session)
        } else {
            pending = nil
        }
        guard let machineSocket = await machine.daemon.connection?.endpoint?.socketPath,
              let localSocket = await services.daemon.connection?.endpoint?.socketPath else {
            throw Failure(message: CloudMoveStrings.notConnected(name), retry: again)
        }
        if update, pending == nil {
            let toastID = "cloud-bring-back-" + tab.id
            try await CloudMachineUpdate.run(services, name: name, socket: machineSocket, cli: cli, toast: toastID, retry: again.updating)
            CloudMove.toast(services, toastID, CloudBringBackStrings.bringing, duration: CloudMove.working)
        }
        let pulled: CloudMoveCLI.Answer
        if pending != nil || toMachine { pulled = CloudMoveCLI.Answer(ok: true) } else { do {
            pulled = try await cli.bringBackPull(socket: machineSocket, local: entry.localRoot, remote: entry.remoteFolder)
        } catch {
            // Timed out or didn't launch: nothing moved, so Retry runs it again on this machine.
            throw Failure(message: CloudBringBackStrings.syncFailed(name, CloudStrings.errorText(error)), retry: again)
        } }
        guard pulled.ok else {
            // A conflict changed nothing here: the chat stays on the machine until the files are settled.
            if pulled.errorCode == "sync_conflict" { throw Failure(message: CloudBringBackStrings.conflict(pulled.conflicts), retry: again) }
            if pulled.errorCode == CloudMoveStrings.outdatedCode { throw Failure(message: CloudBringBackStrings.outdatedMachine(name), retry: again.updating) }
            throw Failure(message: CloudBringBackStrings.syncFailed(name, pulled.error ?? pulled.errorCode ?? ""), retry: again)
        }
        // Move to Another Machine: the target, whose folder the move's relay fills before the chat freezes.
        var target = pending
        // A stop while a new target connects names this run's Retry, never that machine: nothing was copied there yet.
        if toMachine, target == nil {
            do { target = try await CloudMove(services: services).machine(invocation, except: entry.machineID) { nil } } catch let failure as Failure {
                throw Failure(message: failure.message, retry: again)
            }
        }
        var onto: (socket: String, vmKind: String, remotes: [(folder: String, chat: String)])?
        if let target {
            guard let socket = await target.daemon.connection?.endpoint?.socketPath, let folder = CloudMoveFolder(chat: entry.localChat) else {
                throw Failure(message: CloudMoveStrings.notConnected(target.machine.title), retry: again)
            }
            let suffix = Self.targetSuffix(machineID: target.machineID, session: entry.session)
            onto = (socket, await CloudMove.ownerAnswer(target).vmKind, services.cloud.move.workRoots.map { CloudMove.remote(folder, under: $0, suffix: suffix) })
        }
        // From here the chat may land on the target: every stop's Retry is pinned to it (``pending`` above), kept now
        // so a quit or a crash mid-transfer leaves the pin too.
        if let target {
            again = .move(machineID: target.machineID)
            services.cloud.bringBackRetries[tab.id] = again
        }
        var moved = CloudMoveCLI.Answer(ok: false), landing = onto?.remotes.first
        do {
            // A running turn goes on where the chat lands with its last changes (to another machine: relayed; a refused work root, the next).
            for remote in onto.map({ $0.remotes.map(Optional.some) }) ?? [nil] {
                landing = remote
                let sync = onto.map { CloudMoveCLI.FrozenSync(pull: false, socket: $0.socket, local: entry.remoteFolder, remote: remote?.folder ?? "",
                                                              fromSocket: machineSocket, seedLocal: entry.localRoot) }
                    ?? CloudMoveCLI.FrozenSync(pull: true, socket: machineSocket, local: entry.localRoot, remote: entry.remoteFolder)
                moved = try await cli.agentMove(from: machineSocket, surface: tab.surface.rawValue, to: onto?.socket ?? localSocket,
                                                cwd: remote?.chat ?? entry.localChat, sync: sync, askFirst: askFirst, vmKind: onto?.vmKind)
                if moved.ok || moved.errorCode != "fs.permission_denied" { break }
            }
        } catch {
            services.cloud.logger.error("cloud bring back: link agent move: \(String(describing: error), privacy: .public)")
            throw Failure(message: CloudBringBackStrings.unresolved, retry: again)
        }
        guard moved.ok, let session = moved.sessionID else {
            var failure = CloudMoveFailure.bringingBack(moved, machine: name, retry: again, askedFirst: askFirst)
            // A move to another machine keeps its pin through any stop of the transfer.
            if target != nil, failure.retry == nil { failure.retry = again }
            throw failure
        }
        if let target, let landing { return try await landed(on: target, landing, session: session, entry: entry, key: moved.transferID, tab: tab) }
        // The move committed: from here Retry only opens the chat's tab on this Mac. The ledger
        // keeps that (not only memory) until the tab opened.
        let back = CloudMovedChats.BroughtBack(session: session, key: moved.transferID ?? session)
        var committed = entry
        committed.broughtBack = back
        services.cloud.movedChats.record(committed)
        // The chat is back: its grants on the machine end (never failing the bring back).
        services.cloud.accessAsks.chatBroughtBack(machineID: entry.machineID, session: entry.session, services: services)
        try await finish(committed.shown(back), tab: tab)
        return name
    }

    /// A move to another machine that committed: the ledger names the new machine (Bring Back Local and
    /// another move start there), the chat opens there and the old machine's tab closes.
    private func landed(on target: CloudMachineSession, _ remote: (folder: String, chat: String), session: String, entry: CloudMovedChats.Entry,
                       key: String?, tab: TabModel) async throws -> String {
        let name = target.machine.title
        // The old entry goes only once the new one is kept: either way the chat stays one this Mac can bring back.
        if let host = AgentTabStore.registryHost(of: target.daemon) {
            var next = entry
            (next.machineID, next.host, next.session, next.remoteFolder, next.remoteChat) = (target.machineID, host, session, remote.folder, remote.chat)
            services.cloud.movedChats.record(next)
            services.cloud.movedChats.forget(host: entry.host, session: entry.session)
        }
        services.cloud.accessAsks.chatBroughtBack(machineID: entry.machineID, session: entry.session, services: services)
        services.cloud.accessAsks.start(services: services)
        do {
            try await CloudMove(services: services).show(session, harness: entry.harness, on: target, in: remote.chat, name: entry.name, key: key ?? session)
        } catch {
            throw Failure(message: CloudMoveStrings.tabFailed(name, CloudStrings.errorText(error)))
        }
        try? await services.machines.daemon(forTab: tab).connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
        return name
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
            throw Failure(message: CloudBringBackStrings.tabFailed(CloudStrings.errorText(error)), retry: .show(shown))
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
        let workspace = NewWorkspacePlacements.placedKey(in: services.windows) // placed like Cmd-N, not at the daemon's slot
        let created = try await WorkspaceCreation.createWithFirstTab(workspace, name: shown.name, on: connection, repair: services.emptyWorkspaces) { result in
            try await connection.createTerminal(in: result.key, cwd: shown.folder)
            return try await connection.request(NewConversationTabRequest(agentSession: record, workspace: result.workspace,
                                                                          origin: AgentTabStore.createOrigin, mutationID: "cloud-bring-back-" + shown.key))
        }
        services.windows.reveal(workspaceID: workspace.rawValue)
        let tab = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        if let pane = await daemon.store.firstPane(mirroring: workspace) {
            for window in services.windows.controllers { window.state.selection.select(tab, in: pane.id) }
        }
    }
}
