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
///
/// The capture's shell, seed and script and what output it keeps are Rust's (`login_capture_plan`,
/// `cmux_daemon_launch_login_env_accept`; cmux-daemon-launch-core src/login_env.rs).
public struct LoginEnvironment: Sendable {
    public static let shared = Self()

    /// Identity and terminal-session variables that must not leak from the
    /// capturing shell or the app into the daemon and its shells.
    public let excludedKeys: Set<String> = [
        "_", "PWD", "OLDPWD", "SHLVL",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLORTERM",
        "XPC_SERVICE_NAME", "XPC_FLAGS", "__CFBundleIdentifier",
        "CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET", "CMUX_TUI_SESSION",
        "CMUX_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_ENABLE", "CMUX_BUNDLE_ID",
        "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_PANE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID",
        "CMUXD_UNIX_PATH",
    ]

    /// Captures the login env, or returns nil on failure or timeout.
    public func capture(
        shell: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> [String: String]? {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.env")
        let plan = DaemonLaunchRules.call("login_capture_plan", [
            "shell": shell ?? NSNull(), "base": base, "userShell": userShell() ?? NSNull(),
        ]) as? [String: Any]
        guard let shellPath = plan?["shell"] as? String, let arguments = plan?["arguments"] as? [String],
              let seed = plan?["environment"] as? [String: String] else {
            logger.error("login env capture failed: no capture plan")
            return nil
        }
        do {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: shellPath),
                arguments: arguments,
                environment: seed,
                timeout: timeout,
                clock: clock
            )
            guard let env = DaemonLaunchRules.acceptLoginEnvironment(status: result.status, output: result.stdout) else {
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
