import CmuxNextAppCore
import CmuxNextAgentPane
import CmuxNextBridge
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
/// starts in the machine's default directory. `windowID` claims the workspace for that window at the press (`claimNew`;
/// a failure takes it back), so the window waits for it (#31502) and it lands there in the step that first mirrors it; nil
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
        let key = WorkspaceKey.generate(), windows = windows
        if let windowID { windows.claimNew(workspaceID: key.rawValue, window: windowID, frame: frame) } // before its lane runs it
        guard daemon.connection != nil else { return { windows.createDidFail(workspaceID: key.rawValue); throw DaemonError.notConnected } }
        let daemon = daemon, services = windows.services, machine = MachineID(daemon.machineID)
        var row = spawn.slot == nil ? NewWorkspacePlacements.rule(for: windowID, in: windows) : nil
        if !spawn.placesFromCurrent || !spawn.placesBySetting, row?.placement != .afterCurrent { row?.current = nil }
        let rule = spawn.placesBySetting ? row : nil
        // Only a create with a row names itself here; another keeps the daemon's own numbering.
        let name = spawn.name ?? windowID.map { _ in
            SidebarMapping.nextWorkspaceName(in: daemon.store, reserved: PendingWorkspaceRows.shared.reservedNames(on: machine) { services.workspace(id: $0) != nil })
        }
        let named = renamed(name)
        if let windowID, let name {
            let opensPage = WorkspaceCreation.opensPage(spawn, on: daemon, tabs: services.agentTabs)
            let face = SidebarMapping.shared.creatingRow(id: key.rawValue, machine: machine, name: name, opensPage: opensPage)
            SidebarNewRowTimer.shared.began(key.rawValue)
            PendingWorkspaceRows.shared.add(.init(id: key.rawValue, window: windowID, machine: machine, face: face,
                                                  slot: spawn.slot, byDefault: row), name: name)
        }
        WorkspaceLanes.shared.prune(windowID ?? "") { services.workspace(id: $0) != nil }
        if let windowID, let name, let instant = shown(key, name: name, window: windowID, rule: rule) { return instant }
        let windowID = windowID
        return {
            do {
                return try await WorkspaceLanes.shared.create(key, window: windowID, close: { id in
                    let terminals = services.workspace(id: id).map { WorkspaceClose.closing($0, on: daemon) } ?? []
                    _ = await daemon.failure("close-workspace") { connection in
                        try await WorkspaceClose.close(WorkspaceKey(rawValue: id), terminals: terminals, on: connection)
                    }
                }, settle: { await Self.settled(on: daemon) }) { try await named.create(key, rule: rule) }
            } catch {
                windows.createDidFail(workspaceID: key.rawValue)
                throw error
            }
        }
    }

    /// Cmd-N's New Tab page workspace on this Mac, shown in this turn (instant-new-surfaces): the
    /// store shows it with its page (`AgentTabStore.showWorkspace`) and its window selects it
    /// now; the returned work pins its room, then creates it and its first tab in the window's
    /// create lane, and places it at its slot once the daemon has it. Nil: the create waits for
    /// the daemon (a terminal, a command, a chat, another machine).
    private func shown(_ key: WorkspaceKey, name: String, window windowID: String,
                       rule: NewWorkspaceDefaultSlot?) -> (() async throws -> String)? {
        let services = windows.services, daemon = daemon
        guard spawn.opensNewTabPage, spawn.command == nil, spawn.firstChat == nil, spawn.firstSession == nil,
              spawn.browserProfile == nil, spawn.cwd == nil || daemon.isLocal else { return nil }
        let repair: EmptyWorkspaceRepair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
        let room = services.machines.local.store.profile(spawn.profile ?? profile)
        let cwd = spawn.cwd ?? (daemon.isLocal ? room?.defaults : nil)?.cwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (daemon.isLocal ? spawn.inheritedCwd : nil) ?? daemon.defaultCwd
        guard services.agentTabs.showsWorkspaceAtOnce(on: daemon) else { return nil }
        // Claimed at the press (`start`), so the reconcile the intent runs places and selects it in this window in
        // this turn; its slot is placed in the turn the daemon's workspace takes the stand-in over.
        NewWorkspacePlacements.expect(key.rawValue, in: windowID, slot: spawn.slot, byDefault: rule, then: spawn.onListed, windows: windows)
        guard let shown = services.agentTabs.showWorkspace(key, name: name, index: nil, cwd: cwd, token: spawn.inputToken,
                                                           on: daemon, repair: repair) else { return nil }
        // The keys held since the press may go to its page's field once that reports ready.
        services.keyRouter.newTabInputCoordinator.flushAll()
        let windows = windows
        return {
            do {
                return try await WorkspaceLanes.shared.create(key, window: windowID, close: { id in
                    _ = await daemon.failure("close-workspace") { connection in
                        try await WorkspaceClose.close(WorkspaceKey(rawValue: id), terminals: [], on: connection)
                    }
                }, settle: { await Self.settled(on: daemon) }) {
                    // One late-reply budget for the pin, the create and the first tab.
                    let giveUp = DaemonConnection.lateReplyDeadline()
                    if let room, let session = daemon.store.registryID, let home = services.machines.local.connection {
                        try await DaemonConnection.retryingLateReplies(PinWorkspaceRequest.command, until: giveUp) {
                            try await home.pinWorkspace(session: session, key: key, to: room.id)
                        }
                        BenchSpans.mark("cmdN.pinWorkspace.returned")
                    }
                    return try await shown.confirm(giveUp)
                }
            } catch {
                shown.abandon()
                windows.pendingPlacements[key.rawValue] = nil
                windows.pendingPlacementOrder.removeAll { $0 == key.rawValue }
                windows.createDidFail(workspaceID: key.rawValue)
                throw error
            }
        }
    }

    /// The check that `daemon`'s store has applied every event before now (a
    /// create's reply): a write barrier taken without waiting for it.
    private static func settled(on daemon: DaemonService) async -> @MainActor () -> Bool {
        guard let barrier = await daemon.connection?.eventSequence() else { return { false } }
        let store = daemon.store
        return { store.appliedSequence >= barrier }
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
        if let room, let session = daemon.store.registryID, let homeConnection = home.connection {
            try await DaemonConnection.retryingLateReplies(PinWorkspaceRequest.command) {
                try await homeConnection.pinWorkspace(session: session, key: key, to: room.id)
            }
            BenchSpans.mark("cmdN.pinWorkspace.returned")
        }
        if let browserProfile = spawn.browserProfile {
            let qualified = BrowserProfileService.QualifiedWorkspace(session: daemon.store.registryID ?? daemon.machineID, key: key.rawValue)
            try services.browserProfiles.setWorkspaceDefault(browserProfile, for: qualified)
        }
        let defaults = daemon.isLocal ? room?.defaults : nil
        // Local terminals get the app's environment; a Cloud terminal only
        // the caller's keys. Both get the placement keys hooks read.
        var vars = daemon.isLocal ? await services.environment.terminalEnvironmentProvider()() : [:]
        vars.merge(defaults?.env ?? [:]) { _, profile in profile }
        vars.merge(spawn.env) { _, caller in caller }
        vars.merge(DaemonConnection.placementEnvironment(workspace: key, terminal: terminal)) { _, placement in placement }
        let env: [String: String]? = daemon.supports(DaemonCapability.terminalEnv.rawValue) ? vars : nil
        let keep: Bool? = spawn.keep && daemon.supports(DaemonCapability.terminalReap.rawValue) ? true : nil
        let repair: EmptyWorkspaceRepair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
        let cwd = spawn.cwd ?? defaults?.cwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (daemon.isLocal ? spawn.inheritedCwd : nil) ?? daemon.defaultCwd
        BenchSpans.mark("cmdN.create.sending")
        if let page = try await FirstTabHold.creating(key.rawValue, windows: windows, { try await WorkspaceCreation.newTabPage(spawn, key, cwd: cwd, on: daemon, repair: repair, tabs: services.agentTabs) }) { return page }
        let command = spawn.command
        return try await WorkspaceCreation.create(key, name: spawn.name, on: connection, repair: repair) { created in
            // Keyed (terminal id, mutation): a late start is waited for, never taken back (P0 2026-10-30).
            _ = try await connection.createTerminalWaitingForStart(CreateTerminalRequest(
                workspace: .key(created), command: command, cwd: cwd,
                terminalID: terminal, env: env, keep: keep, mutation: connection.mutation()))
            return created.rawValue
        }
    }
}
