import Foundation
import os

/// What the configured cmux-tui binary accepts before it runs an owner.
/// `server ensure` options are not negotiated over the socket (no owner
/// exists yet), so the launcher reads the binary's startup help. Older
/// clients put those options in root help; current clients use `help start`.
extension DaemonLauncher {
    /// True when the binary's help lists `--terminal-reap-grace-seconds` (cmux-daemon-launch-core
    /// `reap_grace_probes` and `lists_reap_grace`). False when it does not, or when the probe fails: an owner
    /// without the grace never reaps (a closed tab's terminal lives on), which is better than an app that
    /// cannot start its daemon at all. The bundled binary always has the option
    /// (`Configuration.binaryIsBundled`), so only an external binary is probed.
    func supportsReapGrace() async -> Bool {
        if configuration.binaryIsBundled { return true }
        let probes = DaemonLaunchRules.call("reap_grace_probes", [String: String](), as: [[String]].self) ?? []
        for arguments in probes {
            do {
                let result = try await ProcessRunner.run(executable: configuration.binary, arguments: arguments,
                                                         environment: nil, timeout: .seconds(5), clock: clock)
                let help = DaemonLaunchRules.Text(text: String(decoding: result.stdout, as: UTF8.self))
                if result.status == 0, DaemonLaunchRules.call("lists_reap_grace", help, as: Bool.self) == true {
                    return true
                }
            } catch {
                Self.capabilityLogger.error("cmux-tui \(arguments.joined(separator: " "), privacy: .public) failed (\(String(describing: error), privacy: .public))")
            }
        }
        Self.capabilityLogger.notice("cmux-tui does not list the terminal reap grace; starting the owner without one")
        return false
    }

    static let capabilityLogger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")
}
