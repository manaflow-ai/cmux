import CmuxNextDaemon
import Foundation

/// Old-app terminal creation params (`working_directory`/`cwd`,
/// `initial_command`, `initial_env`/`startup_environment`) mapped to
/// cmux-tui spawn fields.
enum CompatSpawn {
    static func workingDirectory(_ call: CompatCall) throws -> String? {
        for key in ["working_directory", "cwd"] {
            guard let value = call.params[key], !value.isNull else { continue }
            guard let text = value.stringValue else { throw CompatErrors.invalid("\(key) must be a string") }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            return (trimmed as NSString).expandingTildeInPath
        }
        return nil
    }

    /// Shell command the new terminal runs (`initial_command`).
    static func command(_ call: CompatCall) -> String? {
        call.string("initial_command").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// The allowlisted login environment (`TerminalEnvironment`), the
    /// caller's `initial_env`, and the cmux identity keys hooks and the
    /// CLI read (`CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_SOCKET_PATH`).
    static func environment(_ call: CompatCall, workspaceUUID: String?, surfaceUUID: String?) async -> [String: String] {
        var env = await TerminalEnvironment.shared()()
        for key in ["initial_env", "startup_environment"] {
            for (name, value) in call.params[key]?.objectValue ?? [:] {
                if let text = value.stringValue { env[name] = text }
            }
        }
        if let workspaceUUID { env["CMUX_WORKSPACE_ID"] = workspaceUUID }
        if let surfaceUUID {
            env["CMUX_SURFACE_ID"] = surfaceUUID
            env["CMUX_PANEL_ID"] = surfaceUUID
        }
        if let socket = call.service.router?.transportInfo.socketPath { env["CMUX_SOCKET_PATH"] = socket }
        return env
    }
}
