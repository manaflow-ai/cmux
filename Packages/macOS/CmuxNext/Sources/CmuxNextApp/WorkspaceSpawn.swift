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

    init(cwd: String? = nil, name: String? = nil, command: String? = nil, env: [String: String] = [:], keep: Bool = false,
         profile: ProfileID? = nil) {
        self.cwd = cwd
        self.name = name
        self.command = command
        self.env = env
        self.keep = keep
        self.profile = profile
    }

    /// `newTab` arguments: `cwd`, `name`, `command`, `env` (a JSON object of
    /// strings), `keep`.
    init(_ invocation: ActionInvocation) {
        cwd = invocation["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        command = invocation["command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        keep = invocation["keep"]?.boolValue == true
        profile = invocation["profile"]?.targetValue.map { ProfileID(rawValue: $0.id) }
            ?? invocation["profile"]?.stringValue.flatMap { $0.isEmpty ? nil : ProfileID(rawValue: $0) }
        if let text = invocation["env"]?.stringValue, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            env = object.compactMapValues { $0 as? String }
        }
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
        if let windowID { claimNew(workspaceID: key.rawValue, window: windowID, frame: frame) }
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
        let defaults = daemon.isLocal ? room?.defaults : nil
        // Local terminals get the app's environment; a Cloud terminal only
        // the caller's keys. Both get the placement keys hooks read.
        var vars = daemon.isLocal ? await TerminalEnvironment.shared(overrides: services.environment.terminalEnvironment)() : [:]
        vars.merge(defaults?.env ?? [:]) { _, profile in profile }
        vars.merge(spawn.env) { _, caller in caller }
        vars.merge(DaemonConnection.placementEnvironment(workspace: key, terminal: terminal)) { _, placement in placement }
        let env: [String: String]? = daemon.supports(DaemonCapabilities.terminalEnv) ? vars : nil
        let keep: Bool? = spawn.keep && daemon.supports(DaemonCapabilities.terminalReap) ? true : nil
        let repair: EmptyWorkspaceRepair = services.machines.session(daemon.machineID)?.emptyWorkspaces ?? services.emptyWorkspaces
        let cwd = spawn.cwd ?? defaults?.cwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath } ?? daemon.defaultCwd
        return try await repair.populating(key) {
            let result = try await connection.request(CreateWorkspaceRequest(name: spawn.name, key: key, mutation: connection.mutation()))
            _ = try await connection.request(CreateTerminalRequest(
                workspace: .key(result.key), command: spawn.command, cwd: cwd,
                terminalID: terminal, env: env, keep: keep, mutation: connection.mutation()))
            return result.key.rawValue
        }
    }
}
