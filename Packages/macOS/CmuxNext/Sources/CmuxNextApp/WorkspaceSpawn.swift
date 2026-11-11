import CmuxNextAppCore
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWorkspaceRepair
import Foundation

extension WindowManager {
    /// Creates a workspace and returns its id (`WorkspaceSpawner`).
    func createWorkspace(_ spawn: WorkspaceSpawn, on daemon: DaemonService? = nil, into windowID: String? = nil,
                         frame: CGRect? = nil) async throws -> String {
        try await startWorkspace(spawn, on: daemon, into: windowID, frame: frame)()
    }

    /// Starts a workspace create in this turn: what can show without the daemon shows now (its
    /// row; Cmd-N's workspace and page), and the returned work runs the daemon's part and returns
    /// the workspace id (`WorkspaceSpawner.start`).
    func startWorkspace(_ spawn: WorkspaceSpawn, on daemon: DaemonService? = nil, into windowID: String? = nil,
                        frame: CGRect? = nil) -> () async throws -> String {
        WorkspaceSpawner(windows: self, spawn: spawn, daemon: daemon ?? services.daemon, windowID: windowID, frame: frame).start()
    }
}

/// One workspace create: one terminal, or the New Tab page
/// (`opensNewTabPage`). It waits for the window's earlier creates and
/// closes (`WorkspaceLanes`). The terminal gets this app's launch identity plus
/// `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` (its reserved terminal id), so
/// `cmux` and agent hooks inside it know where they run. On a Cloud machine
/// (`daemon`), it gets no Mac environment (only the placement keys) and
/// starts in the machine's default directory. `windowID` claims the
/// workspace for that window at the press (`claimNew`; a failure releases it),
/// so it lands there in the step that first mirrors it, and the window waits; nil
/// leaves it to reconcile (the most recent window). It goes to `spawn.slot`,
/// else by `workspaces.newPlacement`.
@MainActor
struct WorkspaceSpawner {
    let windows: WindowManager
    var spawn: WorkspaceSpawn
    let daemon: DaemonService
    let windowID: String?
    let frame: CGRect?

    /// The key and the name are fixed at the press, so a close pressed while
    /// this create waits its turn or is in flight takes exactly this
    /// workspace, and the window shows its final row from the press
    /// (`PendingWorkspaceRows`), at the slot the setting gives against the workspace the window shows now (`row`; a
    /// create that places itself, New Workspace in New Group: where the daemon lists it). With no name asked for, the create
    /// sends the daemon's own next default (`SidebarMapping.defaultWorkspaceName`),
    /// so the row's title is the daemon's from the first frame.
    func start() -> () async throws -> String {
        // A plain Cmd-N into a window shows the workspace its daemon reserved before the key (`AgentTabStore.reserveWorkspace`).
        let use = daemon.connection == nil ? nil : daemon.store.reservedWorkspaceUse(plain: windowID != nil && spawn.isPlainNewTabPage && windows.services.agentTabs.showsWorkspaceAtOnce(on: daemon), home: windows.services.daemon.store)
        if let span = use?.span { BenchSpans.mark(span) }
        let key = spawn.key ?? use?.key ?? WorkspaceKey.generate(), daemon = daemon, services = windows.services, machine = MachineID(daemon.machineID)
        let (row, rule) = spawn.placement(setting: NewWorkspacePlacements.rule(for: windowID, in: windows), opening: key.rawValue, in: windowID, tells: windows.registry.closeSelection) // one read of the rows; the rule hears of a person's create before the window can show it
        if let windowID { windows.claimNew(workspaceID: key.rawValue, window: windowID, frame: frame) }
        guard daemon.connection != nil else { return { [windows] in throw windows.createFailed(key.rawValue, DaemonError.notConnected) } }
        // Only a create with a row names itself here; another keeps the daemon's own numbering.
        let name = spawn.rowName(inWindow: windowID != nil) {
            SidebarMapping.nextWorkspaceName(in: daemon.store, reserved: PendingWorkspaceRows.shared.reservedNames(on: machine) { services.workspace(id: $0) != nil })
        }
        let named = renamed(name)
        if let windowID, let name {
            let opensPage = WorkspaceCreation.opensPage(spawn, on: daemon, tabs: services.agentTabs)
            SidebarNewRowTimer.shared.began(key.rawValue)
            PendingWorkspaceRows.shared.add(creating: key.rawValue, window: windowID, machine: machine, name: name, opensPage: opensPage, slot: spawn.slot, byDefault: row)
        }
        WorkspaceLanes.shared.prune(windowID ?? "") { services.workspace(id: $0) != nil }
        if let windowID, let name, let instant = shown(key, name: name, window: windowID, rule: rule) { return instant }
        if use?.key != nil { services.agentTabs.releaseReservedWorkspace(on: daemon.store, .unshown) } // its key names no other workspace
        let windowID = windowID
        return {
            do {
                return try await WorkspaceLanes.shared.create(key, window: windowID, close: { id in
                    let terminals = services.workspace(id: id).map { WorkspaceClose.closing($0, on: daemon) } ?? []
                    _ = await daemon.failure("close-workspace") { connection in
                        try await WorkspaceClose.close(WorkspaceKey(rawValue: id), terminals: terminals, on: connection)
                    }
                }, settle: { await daemon.settledCheck() }) { try await named.create(key, rule: rule) }
            } catch {
                windows.forgetCreate(key.rawValue)
                throw windows.createFailed(key.rawValue, error)
            }
        }
    }

    /// Cmd-N's New Tab page workspace on this Mac, or a chat's, shown in this turn (instant-new-surfaces): the
    /// store shows it with its page or chat (`AgentTabStore.showWorkspace`) and its window selects it
    /// now; the returned work pins its room, then creates it and its first tab in the window's
    /// create lane, and places it at its slot once the daemon has it. Nil: the create waits for
    /// the daemon (a terminal, a command, another machine).
    private func shown(_ key: WorkspaceKey, name: String, window windowID: String,
                       rule: NewWorkspaceDefaultSlot?) -> (() async throws -> String)? {
        let services = windows.services, daemon = daemon, windows = windows
        guard spawn.showsBeforeDaemon(local: daemon.isLocal), services.agentTabs.showsWorkspaceAtOnce(on: daemon) else { return nil }
        let repair: EmptyWorkspaceRepair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
        let room = services.machines.local.store.profile(spawn.profile ?? profile)
        let cwd = spawn.startFolder(roomFolder: room?.defaults?.cwd, local: daemon.isLocal, daemonDefault: daemon.defaultCwd)
        // Claimed at the press (`start`): the intent's reconcile selects it in this window in this turn, and the window swaps to it in this turn's
        // frame, before its commit (not in the key's handler: SWITCH STALL 6, nor a hop later: SWITCH STALL 4); its slot is placed once the daemon has it.
        NewWorkspacePlacements.expect(key.rawValue, in: windowID, slot: spawn.slot, byDefault: rule, then: spawn.onListed, windows: windows)
        guard let shown = services.agentTabs.showWorkspace(key, name: name, index: nil, cwd: cwd, token: spawn.inputToken, chat: spawn.firstChat,
                                                           session: spawn.firstSession.map { ($0, nil, false) }, on: daemon, repair: repair) else { return nil }
        if let controller = windows.controller(for: windowID), controller.state.workspaceID == key.rawValue { MainRunLoopBlock.perform { [weak controller] in controller.map { $0.showWorkspace(requested: $0.state.workspaceID) } } }
        // The keys held since the press may go to its page's field once that reports ready.
        services.keyRouter.newTabInputCoordinator.flushAll()
        return {
            do {
                return try await WorkspaceLanes.shared.create(key, window: windowID, close: { id in
                    _ = await daemon.failure("close-workspace") { connection in
                        try await WorkspaceClose.close(WorkspaceKey(rawValue: id), terminals: [], on: connection)
                    }
                }, settle: { await daemon.settledCheck() }) {
                    // One late-reply budget for the pin, the create and the first tab.
                    let giveUp = DaemonConnection.lateReplyDeadline()
                    if try await services.machines.local.connection?.pinWorkspaceBeforeCreate(session: daemon.store.registryID, key: key, to: room?.id, until: giveUp) == true {
                        BenchSpans.mark("cmdN.pinWorkspace.returned")
                    }
                    return try await shown.confirm(giveUp)
                }
            } catch {
                shown.abandon()
                windows.forgetCreate(key.rawValue)
                throw windows.createFailed(key.rawValue, error)
            }
        }
    }

    /// The profile the workspace is born in: its window's, else the active
    /// window's, else `default`.
    private var profile: ProfileID {
        windowID.flatMap { windows.states[$0]?.profileID } ?? windows.active?.state.profileID ?? .defaultProfile
    }

    private func renamed(_ name: String?) -> Self {
        var copy = self
        copy.spawn.name = name
        return copy
    }

    private func create(_ key: WorkspaceKey, rule: NewWorkspaceDefaultSlot?) async throws -> String {
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        let services = windows.services
        NewWorkspacePlacements.expect(key.rawValue, in: windowID, slot: spawn.slot, byDefault: rule,
                                      then: windowID == nil ? nil : spawn.onListed, windows: windows)
        let terminal = TerminalID.generate()
        // The workspace is born in its window's room (or the one asked for):
        // pinned there in the home session before the create command, so no
        // snapshot shows it in another room; its first terminal gets the
        // room's terminal defaults (data-model.md 3.2, 3.3).
        let home = services.machines.local
        let room = home.store.profile(spawn.profile ?? profile)
        if try await home.connection?.pinWorkspaceBeforeCreate(session: daemon.store.registryID, key: key, to: room?.id) == true {
            BenchSpans.mark("cmdN.pinWorkspace.returned")
        }
        if let browserProfile = spawn.browserProfile {
            let qualified = BrowserProfileService.QualifiedWorkspace(session: daemon.store.registryID ?? daemon.machineID, key: key.rawValue)
            try services.browserProfiles.setWorkspaceDefault(browserProfile, for: qualified)
        }
        // Local terminals get the app's environment; a Cloud terminal only
        // the caller's keys. Both get the placement keys hooks read.
        let start = spawn.terminalStart(app: daemon.isLocal ? await services.environment.terminalEnvironmentProvider(prefersGhosttyTerm: { [weak services] in services?.settings?.snapshot.terminalTerm == .xtermGhostty })() : [:], room: room?.defaults, local: daemon.isLocal, daemonDefault: daemon.defaultCwd,
                                        workspace: key, terminal: terminal, sendsEnv: daemon.supports(DaemonCapability.terminalEnv.rawValue), reaps: daemon.supports(DaemonCapability.terminalReap.rawValue))
        let repair: EmptyWorkspaceRepair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
        BenchSpans.mark("cmdN.create.sending")
        if let page = try await FirstTabHold.creating(key.rawValue, windows: windows, { try await WorkspaceCreation.newTabPage(spawn, key, cwd: start.cwd, on: daemon, repair: repair, tabs: services.agentTabs) }) { return page }
        // A browser workspace: one request, and its window shows it once the tab is there (no terminal, no empty frame).
        if let tab = spawn.firstBrowser, daemon.supports(DaemonCapability.workspaceFirstTab.rawValue) { return try await FirstTabHold.creating(key.rawValue, windows: windows) { try await spawn.madeFirstBrowser(repair.createBrowserWorkspace(key, name: spawn.name, tab: tab, on: connection), on: connection) } ?? key.rawValue }
        let command = spawn.command, onFirstTerminal = spawn.onFirstTerminal
        return try await WorkspaceCreation.create(key, name: spawn.name, on: connection, repair: repair) { created in
            // Keyed (terminal id, mutation): a late start is waited for, never taken back (P0 2026-10-30).
            let started = try await connection.createTerminalWaitingForStart(CreateTerminalRequest(
                workspace: .key(created), command: command, cwd: start.cwd,
                terminalID: terminal, env: start.env, keep: start.keep, mutation: connection.mutation()))
            try await onFirstTerminal?(connection, started)
            return created.rawValue
        }
    }
}
