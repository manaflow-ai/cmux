public import Foundation
import os

/// The user's login-shell environment.
///
/// A Finder- or Dock-launched app gets launchd's minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`). The cmux-tui owner inherits the env of
/// whoever runs `server ensure`, and every PTY it spawns inherits the owner's
/// env; the raw protocol has no per-terminal `env` field. So the app captures
/// `$SHELL -l -i -c 'env -0'` once and launches the daemon with it
/// (plans/cmux-next/cmux-tui-contract.md section 5, "Shell environment").
public enum LoginEnvironment {
    /// Printed before `env -0` so rc-file chatter on stdout is skipped.
    static let marker = "__CMUX_NEXT_LOGIN_ENV__"

    /// Identity and terminal-session variables that must not leak from the
    /// capturing shell or the app into the daemon and its shells.
    public static let excludedKeys: Set<String> = [
        "_", "PWD", "OLDPWD", "SHLVL",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLORTERM",
        "XPC_SERVICE_NAME", "XPC_FLAGS", "__CFBundleIdentifier",
        "CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET", "CMUX_TUI_SESSION",
        "CMUX_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_ENABLE", "CMUX_BUNDLE_ID", "CMUX_TAG",
        "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_PANE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID",
        "CMUXD_UNIX_PATH",
    ]

    /// Captures the login env, or returns nil on failure or timeout.
    public static func capture(
        shell: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> [String: String]? {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.env")
        let shellPath = shell ?? base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? userShell() ?? "/bin/zsh"
        let script = "printf '\\n\(marker)\\n'; /usr/bin/env -0"
        do {
            // HOME/USER/LOGNAME must be right for rc files; the rest comes from the shell.
            var seed: [String: String] = [:]
            for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] { seed[key] = base[key] }
            seed["SHELL"] = shellPath
            seed["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: shellPath),
                arguments: ["-l", "-i", "-c", script],
                environment: seed,
                timeout: timeout,
                clock: clock
            )
            guard result.status == 0, let env = parse(result.stdout), env["PATH"] != nil else {
                logger.error("login env capture failed: status \(result.status)")
                return nil
            }
            return env
        } catch {
            logger.error("login env capture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Parses `<noise>\n<marker>\n` followed by NUL-separated `KEY=value`.
    static func parse(_ output: Data) -> [String: String]? {
        let markerLine = Data("\n\(marker)\n".utf8)
        guard let range = output.range(of: markerLine) else { return nil }
        var env: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: 0, omittingEmptySubsequences: true) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                  let equals = text.firstIndex(of: "=") else { continue }
            env[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return env.isEmpty ? nil : env
    }

    /// Environment for `server ensure`: the login env (or the app env when
    /// capture failed) minus excluded keys, plus `overrides`.
    public static func daemonEnvironment(
        login: [String: String]?,
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var env = login ?? base
        if login == nil, let path = env["PATH"], !path.contains("/opt/homebrew/bin") {
            // Best effort when capture failed: add the common tool prefixes.
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        for key in excludedKeys { env.removeValue(forKey: key) }
        for (key, value) in overrides { env[key] = value }
        return env
    }

    private static func userShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }
}
