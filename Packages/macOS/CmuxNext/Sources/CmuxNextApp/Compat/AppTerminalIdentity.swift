import CmuxNextControl
import CmuxNextDaemon
import Foundation

/// cmux keys every terminal the app spawns gets, so `cmux …` run inside a
/// cmux-next terminal (agents, hooks, scripts) reaches this app's control
/// socket instead of a default or inherited one. `LoginEnvironment` drops
/// these keys from the inherited environment on purpose; they are set here
/// from this process's own identity.
enum AppTerminalIdentity {
    static func environment(processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                            bundle: Bundle = .main) -> [String: String] {
        let bundleID = bundle.bundleIdentifier ?? processEnvironment["CMUX_BUNDLE_ID"]
        var env = [
            "CMUX_SOCKET_PATH": ControlSocketPath.resolve(bundleID: bundleID, environment: processEnvironment,
                                                          isDebugBuild: ControlService.isDebugBuild),
        ]
        if let bundleID { env["CMUX_BUNDLE_ID"] = bundleID }
        return env
    }

    /// `TerminalEnvironment`'s allowlist plus these keys.
    static func configuration() -> DaemonConnection.Configuration {
        let base = TerminalEnvironment.shared()
        let identity = environment()
        return DaemonConnection.Configuration(terminalEnvironment: {
            var env = await base()
            env.merge(identity) { _, own in own }
            return env
        })
    }
}
