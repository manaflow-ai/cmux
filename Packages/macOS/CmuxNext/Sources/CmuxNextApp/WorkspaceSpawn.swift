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

    init(cwd: String? = nil, name: String? = nil, command: String? = nil, env: [String: String] = [:]) {
        self.cwd = cwd
        self.name = name
        self.command = command
        self.env = env
    }

    /// `newTab` arguments: `cwd`, `name`, `command`, `env` (a JSON object of strings).
    init(_ invocation: ActionInvocation) {
        cwd = invocation["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        command = invocation["command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
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
    /// and starts in the machine's own default directory.
    func createWorkspace(_ spawn: WorkspaceSpawn, on daemon: DaemonService? = nil) async throws -> String {
        let daemon = daemon ?? services.daemon
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        let key = WorkspaceKey.generate()
        let terminal = TerminalID.generate()
        var environment: [String: String]?
        if daemon.isLocal {
            var env = await TerminalEnvironment.shared(overrides: services.environment.launch.terminalEnvironment)()
            env.merge(spawn.env) { _, caller in caller }
            env["CMUX_WORKSPACE_ID"] = Self.uuidForm(key.rawValue)
            env["CMUX_SURFACE_ID"] = Self.uuidForm(terminal.rawValue)
            env["CMUX_PANEL_ID"] = env["CMUX_SURFACE_ID"]
            environment = env
        } else if !spawn.env.isEmpty {
            environment = spawn.env
        }
        let repair: EmptyWorkspaceRepair = services.machines.session(daemon.machineID)?.emptyWorkspaces ?? services.emptyWorkspaces
        let cwd = spawn.cwd ?? daemon.defaultCwd
        let env = environment
        return try await repair.populating(key) {
            let result = try await connection.request(CreateWorkspaceRequest(name: spawn.name, key: key, mutation: connection.mutation()))
            _ = try await connection.request(CreateTerminalRequest(
                workspace: .key(result.key), command: spawn.command, cwd: cwd,
                terminalID: terminal, env: env, mutation: connection.mutation()))
            return result.key.rawValue
        }
    }

    /// Uppercase 8-4-4-4-12 form of a UUID or 32-hex id (the old app's ids).
    static func uuidForm(_ raw: String) -> String {
        let hex = raw.replacingOccurrences(of: "-", with: "").uppercased()
        guard hex.count == 32 else { return raw }
        let h = Array(hex)
        return [h[0..<8], h[8..<12], h[12..<16], h[16..<20], h[20..<32]].map { String($0) }.joined(separator: "-")
    }
}
