import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// What a new workspace's first terminal starts with. The keyboard, menu,
/// and palette pass nothing; the CLI (`cmux new-workspace`) passes a cwd,
/// name, command, and extra environment through `newTab`'s arguments.
struct WorkspaceSpawn: Sendable {
    var cwd: String?
    var name: String?
    var command: String?
    var env: [String: String] = [:]
    /// The first terminal outlives its tab (`--keep`; `terminal-reap-v1`).
    var keep = false
    /// Room the workspace is born in; nil = the target window's room.
    var profile: ProfileID?
    /// Browser profile of the workspace's new browser tabs; nil = its room's.
    var browserProfile: String?
    /// Where the new workspace goes in its window's sidebar; nil leaves it
    /// where the daemon puts it (after the loose rows).
    var slot: WorkspaceSlot?
    /// Runs once the daemon reports the workspace and its window lists it
    /// (after the slot is applied), with the window's sidebar.
    var onListed: (@MainActor @Sendable (String, SidebarBridge) -> Void)?
    /// A person's new workspace (sidebar +, the New tile, Cmd-N, first
    /// launch, a new window) opens on the New Tab page; scripts and a spawn
    /// with a `command` get a terminal. Also a terminal where the page
    /// cannot run (a Cloud machine, a build without the agent page).
    var opensNewTabPage = false

    init(cwd: String? = nil, name: String? = nil, command: String? = nil, env: [String: String] = [:], keep: Bool = false,
         profile: ProfileID? = nil) {
        self.cwd = cwd
        self.name = name
        self.command = command
        self.env = env
        self.keep = keep
        self.profile = profile
    }

    /// A workspace opened in `directory` (the Finder service "New cmux
    /// Workspace Here"), named after the folder like `newTab` with only a
    /// `cwd`; nil starts in the default directory and the daemon names it.
    init(opening directory: String?) {
        self.init(cwd: directory, name: directory.flatMap(Self.folderName))
    }

    /// `newTab` arguments: `cwd`, `name`, `command`, `env` (a JSON object of
    /// strings), `keep`. A workspace opened in a `cwd` without a `name`
    /// (`cmux open <dir>`, `cmux <dir>` on an explicit socket,
    /// `new-workspace --cwd`) is named
    /// after the folder, like Open Folder…
    init(_ invocation: ActionInvocation) {
        cwd = invocation["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? cwd.flatMap(Self.folderName)
        command = invocation["command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        keep = invocation["keep"]?.boolValue == true
        profile = invocation["profile"]?.targetValue.map { ProfileID(rawValue: $0.id) }
            ?? invocation["profile"]?.stringValue.flatMap { $0.isEmpty ? nil : ProfileID(rawValue: $0) }
        if let text = invocation["env"]?.stringValue, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            env = object.compactMapValues { $0 as? String }
        }
    }

    /// The name of a workspace opened in `directory`: the folder's name
    /// without surrounding whitespace, or nil for the filesystem root or a
    /// blank name (the daemon names it).
    static func folderName(_ directory: String) -> String? {
        let name = URL(fileURLWithPath: directory).standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }
}

extension WindowManager {
    /// Creates a workspace with one terminal and returns its id. The
    /// terminal gets this app's launch identity plus `CMUX_WORKSPACE_ID` and
    /// `CMUX_SURFACE_ID` (its reserved terminal id), so `cmux` and agent
    /// hooks inside it know where they run.
    /// On a Cloud machine (`daemon`), the terminal gets no Mac environment
    /// (only the placement keys) and starts in the machine's own default
    /// directory.
    /// `windowID` claims the workspace for that window before the command
    /// is sent (`claimNew`), so it lands there, or opens that window, in the
    /// step that first mirrors it; nil leaves it to reconcile (the most
    /// recent window).
    func createWorkspace(_ spawn: WorkspaceSpawn, on daemon: DaemonService? = nil, into windowID: String? = nil,
                         frame: CGRect? = nil) async throws -> String {
        let daemon = daemon ?? services.daemon
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        let key = WorkspaceKey.generate()
        if let windowID {
            if spawn.slot != nil || spawn.onListed != nil {
                pendingPlacements[key.rawValue] = PendingPlacement(window: windowID, slot: spawn.slot, then: spawn.onListed)
            }
            claimNew(workspaceID: key.rawValue, window: windowID, frame: frame)
        }
        let terminal = TerminalID.generate()
        // The workspace is born in its window's room (or the one asked for):
        // pinned there in the home session before the create command, so no
        // snapshot shows it in another room; its first terminal gets the
        // room's terminal defaults (data-model.md 3.2, 3.3).
        let home = services.machines.local
        let room = home.store.profile(spawn.profile ?? profileForNewWorkspace(window: windowID))
        if let room, let session = daemon.store.registryID, let homeConnection = home.connection {
            try await homeConnection.pinWorkspace(session: session, key: key, to: room.id)
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
        let env: [String: String]? = daemon.supports(DaemonCapabilities.shared.terminalEnv) ? vars : nil
        let keep: Bool? = spawn.keep && daemon.supports(DaemonCapabilities.shared.terminalReap) ? true : nil
        let repair: EmptyWorkspaceRepair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
        let cwd = spawn.cwd ?? defaults?.cwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath } ?? daemon.defaultCwd
        return try await WorkspaceCreation.create(key, name: spawn.name, on: connection, repair: repair) { created in
            _ = try await connection.request(CreateTerminalRequest(
                workspace: .key(created), command: spawn.command, cwd: cwd,
                terminalID: terminal, env: env, keep: keep, mutation: connection.mutation()))
            return created.rawValue
        }
    }
}
