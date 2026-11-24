import Foundation
import os

/// What the configured cmux-tui binary accepts before it runs an owner.
/// `server ensure` options are not negotiated over the socket (no owner
/// exists yet), so the launcher reads the binary's startup help. Older
/// clients put those options in root help; current clients use `help start`.
extension DaemonLauncher {
    static let reapGraceOption = "--terminal-reap-grace-seconds"

    /// True when the binary's help lists `--terminal-reap-grace-seconds`.
    /// False when it does not, or when the probe fails: an owner without
    /// the grace never reaps (a closed tab's terminal lives on), which is
    /// better than an app that cannot start its daemon at all. The bundled
    /// binary always has the option (`Configuration.binaryIsBundled`), so
    /// only an external binary is probed.
    func supportsReapGrace() async -> Bool {
        if configuration.binaryIsBundled { return true }
        for arguments in [["--help"], ["help", "start"]] {
            do {
                let result = try await ProcessRunner.run(executable: configuration.binary, arguments: arguments,
                                                         environment: nil, timeout: .seconds(5), clock: clock)
                if result.status == 0 && Self.listsReapGrace(String(decoding: result.stdout, as: UTF8.self)) {
                    return true
                }
            } catch {
                Self.capabilityLogger.error("cmux-tui \(arguments.joined(separator: " "), privacy: .public) failed (\(String(describing: error), privacy: .public))")
            }
        }
        Self.capabilityLogger.notice("cmux-tui does not list \(Self.reapGraceOption, privacy: .public); starting the owner without a reap grace")
        return false
    }

    static func listsReapGrace(_ help: String) -> Bool {
        help.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init) == reapGraceOption
        }
    }

    /// Thin call site, before the app quits for an update: `server hold-terminals` of the bundled
    /// binary on this launcher's session marks every terminal with no tab and no `keep` mark as
    /// kept, so the reaper of the running owner (of any build) leaves them when this app's attach
    /// streams end; the next owner lifts the mark once a client streams them again (cmux-tui
    /// `cli/lifecycle.rs`, `mux/update_hold.rs`). Bounded; a failure is logged and the quit goes on.
    public func holdTerminalsForUpdate() async {
        guard configuration.binaryIsBundled else { return }
        do {
            let result = try await ProcessRunner.run(
                executable: configuration.binary,
                arguments: ["--session", configuration.session, "--json", "server", "hold-terminals"],
                environment: await ensureEnvironment(), timeout: .seconds(3), clock: clock)
            Self.capabilityLogger.notice("update hold exit \(result.status): \(String(decoding: result.stdout, as: UTF8.self), privacy: .public)")
        } catch {
            Self.capabilityLogger.error("update hold failed: \(String(describing: error), privacy: .public)")
        }
    }

    static let capabilityLogger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")
}
