public import Foundation
import os

/// The user's login-shell environment.
///
/// A Finder- or Dock-launched app gets launchd's minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`). The cmux-tui owner inherits the env of
/// whoever runs `server ensure`, and every PTY it spawns inherits the owner's
/// env. So the app captures `$SHELL -l -i -c 'env -0'` once, launches the
/// daemon with its allowlisted subset, and sends the same subset as
/// per-terminal `env` (`terminal-env-v1`). See `TerminalEnvironment` for why
/// the full login env never leaves the app.
public struct LoginEnvironment: Sendable {
    public static let shared = Self()

    /// Captures the login env, or returns nil on failure or timeout. The shell, its arguments and its seed
    /// environment (`HOME`, `USER`, `LOGNAME` right for rc files, a minimal `PATH`) and the reading of its
    /// output are cmux-daemon-launch-core's (`login_capture_plan`, `cmux_daemon_launch_login_env_accept`).
    public func capture(
        shell: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> [String: String]? {
        struct Request: Encodable { var shell: String?, base: [String: String], userShell: String? }
        struct Plan: Decodable { var shell: String, arguments: [String], environment: [String: String] }
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.env")
        guard let plan = DaemonLaunchRules.call("login_capture_plan", Request(shell: shell, base: base, userShell: userShell()),
                                                as: Plan.self) else {
            logger.error("login env capture failed: the launch rules did not answer")
            return nil
        }
        do {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: plan.shell),
                arguments: plan.arguments,
                environment: plan.environment,
                timeout: timeout,
                clock: clock
            )
            guard let env = DaemonLaunchRules.acceptLoginCapture(status: result.status, output: result.stdout) else {
                logger.error("login env capture failed: status \(result.status)")
                return nil
            }
            return env
        } catch {
            logger.error("login env capture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Environment for `server ensure`: the allowlisted login env (or app env
    /// when capture failed), the app's process identity keys, and
    /// `overrides`. Same as `TerminalEnvironment.instance.daemon(login:base:overrides:)`.
    public func daemonEnvironment(
        login: [String: String]?,
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        TerminalEnvironment.instance.daemon(login: login, base: base, overrides: overrides)
    }

    /// The login `PATH` the app last captured (this launch's or a previous
    /// one's, `LoginEnvironmentStore`), without running the shell; nil when
    /// none was ever captured. The Chief owner gives it to the brains it
    /// starts, so they and their acpmux find the harnesses a terminal finds.
    public func rememberedPath() -> String? {
        LoginEnvironmentStore.standard().load()?["PATH"]
    }

    private func userShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }
}
