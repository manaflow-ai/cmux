import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite struct LauncherTests {
    @Test func sessionNames() throws {
        #expect(try DaemonLauncher.sessionName(tag: nil) == "cmux-app")
        #expect(try DaemonLauncher.sessionName(tag: "dmn") == "cmux-app-dmn")
        #expect(try DaemonLauncher.sessionName(tag: "feat/x y") == "cmux-app-feat-x-y")
        #expect(throws: DaemonError.self) { try DaemonLauncher.sessionName(tag: "..") }
        #expect(DaemonLauncher.tagStateDirectory(tag: "dmn").path.hasSuffix("cmux/tags/dmn/tui"))
    }

    @Test func parsesEnsureOutput() throws {
        let stdout = Data("""
        warning: something
        {"generation":"cd030a83-d78e-4e46-a7e2-44ead79f7928","message":"local server started","pid":54710,"session":"s","socket":"/tmp/x.sock","status":"started"}

        """.utf8)
        let result = try DaemonLauncher.parseEnsure(ProcessResult(status: 0, stdout: stdout, stderr: Data()))
        #expect(result.status == "started")
        #expect(result.endpoint == DaemonEndpoint(socketPath: "/tmp/x.sock", pid: 54710, generation: "cd030a83-d78e-4e46-a7e2-44ead79f7928"))

        #expect(throws: DaemonError.launchFailed("exit 1: different session")) {
            try DaemonLauncher.parseEnsure(ProcessResult(status: 1, stdout: Data(), stderr: Data("different session\n".utf8)))
        }
    }

    /// cmux-tui derives the owner socket from `$XDG_RUNTIME_DIR`/`$TMPDIR`.
    /// Two launches of the same app with different `TMPDIR`s must still
    /// ask for the same socket, or the second spawns a rival owner that
    /// cannot take the session lock and the app never connects.
    @Test func ensureUsesTheUserTempDirectoryWhateverTheLaunchTMPDIR() async throws {
        let binary = URL(fileURLWithPath: "/usr/bin/true")
        let configuration = DaemonLauncher.Configuration(binary: binary, session: "cmux-app-t", stateDirectory: URL(fileURLWithPath: "/tmp/state"))
        let fromFinder = DaemonLauncher(configuration: configuration, environment: { ["TMPDIR": "/var/folders/xx/T/", "PATH": "/usr/bin"] })
        let fromAgent = DaemonLauncher(configuration: configuration, environment: { ["TMPDIR": "/tmp/agent-tmp/", "XDG_RUNTIME_DIR": "/run/x"] })
        let bare = DaemonLauncher(configuration: configuration, environment: { [:] })
        let expected = DaemonLauncher.userTemporaryDirectory().path
        #expect(expected.hasPrefix("/var/folders/") || expected == "/tmp")
        for launcher in [fromFinder, fromAgent, bare] {
            let env = await launcher.ensureEnvironment()
            #expect(env["TMPDIR"] == expected)
            #expect(env["XDG_RUNTIME_DIR"] == nil)
            #expect(env["CMUX_TUI_STATE_DIR"] == "/tmp/state")
        }
    }

    @Test func parsesBuildCommit() {
        #expect(DaemonLauncher.parseBuildCommit("cmux 0.1.0 (436909bb4319368e8ecc1b6480f73667bd0f2c1d; ghostty e168fd3)\n")
                == "436909bb4319368e8ecc1b6480f73667bd0f2c1d")
        #expect(DaemonLauncher.parseBuildCommit("cmux 0.1.0") == nil)
    }

    @Test func binaryOverrideWins() throws {
        let url = try DaemonLauncher.resolveBinary(bundle: .main, environment: [DaemonLauncher.binaryOverrideKey: "/bin/ls"])
        #expect(url.path == "/bin/ls")
        #expect(throws: DaemonError.self) {
            try DaemonLauncher.resolveBinary(bundle: .main, environment: [DaemonLauncher.binaryOverrideKey: "/nonexistent"])
        }
    }

    @Test func parsesLoginEnvironmentAfterMarker() throws {
        var output = Data("motd line\nprompt junk\n\(LoginEnvironment.marker)\n".utf8)
        output.append(Data("PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/u\0MULTI=a=b\nc\0".utf8))
        let env = try #require(LoginEnvironment.parse(output))
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env["MULTI"] == "a=b\nc")
        #expect(env["HOME"] == "/Users/u")
        #expect(LoginEnvironment.parse(Data("no marker".utf8)) == nil)
    }

    @Test func daemonEnvironmentIsAllowlistedPlusIdentityAndOverrides() {
        let login = [
            "PATH": "/opt/homebrew/bin:/usr/bin", "MANPATH": "/m", "INFOPATH": "/i", "LANG": "en_US.UTF-8",
            "LC_ALL": "C", "SHELL": "/bin/zsh", "TERMINFO_DIRS": "/t", "XDG_CONFIG_HOME": "/x",
            "HOMEBREW_PREFIX": "/opt/homebrew", "HOMEBREW_CELLAR": "/c", "HOMEBREW_REPOSITORY": "/r",
            "CMUX_NEXT_FLAG": "1", "CMUX_TUI_SOCKET": "/tmp/leak", "CMUX_SURFACE_ID": "9",
            "SHLVL": "2", "EDITOR": "vim", "GITHUB_TOKEN": "ghp_secret", "AWS_SECRET_ACCESS_KEY": "s", "HOME": "/login-home",
        ]
        let base = ["HOME": "/Users/u", "USER": "u", "TMPDIR": "/tmp/u", "SSH_AUTH_SOCK": "/tmp/agent", "OPENAI_API_KEY": "sk", "CMUX_TAG": "t1"]
        let env = LoginEnvironment.daemonEnvironment(login: login, base: base, overrides: ["CMUX_TUI_STATE_DIR": "/tmp/state"])
        for key in ["PATH", "MANPATH", "INFOPATH", "LANG", "LC_ALL", "SHELL", "TERMINFO_DIRS", "XDG_CONFIG_HOME",
                    "HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY", "CMUX_NEXT_FLAG"] {
            #expect(env[key] == login[key], "\(key)")
        }
        for key in ["CMUX_TUI_SOCKET", "CMUX_SURFACE_ID", "SHLVL", "EDITOR", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY"] {
            #expect(env[key] == nil, "\(key)")
        }
        // Process identity comes from the app, never the login shell.
        #expect(env["HOME"] == "/Users/u")
        #expect(env["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(env["CMUX_TAG"] == "t1")
        #expect(env["CMUX_TUI_STATE_DIR"] == "/tmp/state")

        // Terminals get the allowlist without the daemon's identity keys.
        let terminal = TerminalEnvironment.terminal(login: login, base: base)
        #expect(terminal["HOME"] == nil)
        #expect(terminal["SSH_AUTH_SOCK"] == nil)
        #expect(terminal["GITHUB_TOKEN"] == nil)
        #expect(terminal["PATH"] == login["PATH"])
        #expect(terminal["CMUX_TAG"] == "t1")

        let fallback = LoginEnvironment.daemonEnvironment(login: nil, base: ["PATH": "/usr/bin:/bin"], overrides: [:])
        #expect(fallback["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    /// The `CMUX_` prefix must not carry credentials into terminals (every
    /// program in them could read them, and terminal-env-v1 writes each
    /// terminal's env to the daemon state directory).
    @Test func credentialCMUXKeysNeverReachTerminalsOrTheDaemon() {
        let secrets = ["CMUX_DOGFOOD_STACK_PASSWORD": "p1", "CMUX_UITEST_STACK_PASSWORD": "p2",
                       "CMUX_SOCKET_PASSWORD": "p3", "CMUX_AUTH_CREDENTIALS_FILE": "/Users/u/.secrets/x.env",
                       "CMUX_RELAY_TOKEN": "t", "CMUX_API_KEY": "k", "CMUX_CLIENT_SECRET": "s"]
        let login = secrets.merging(["PATH": "/usr/bin", "CMUX_TAG": "t1"]) { a, _ in a }
        let base = secrets.merging(["HOME": "/Users/u", "CMUX_TAG": "t1"]) { a, _ in a }
        let terminal = TerminalEnvironment.terminal(login: login, base: base)
        let daemon = TerminalEnvironment.daemon(login: login, base: base, overrides: [:])
        for key in secrets.keys {
            #expect(terminal[key] == nil, "\(key)")
            #expect(daemon[key] == nil, "\(key)")
        }
        #expect(terminal["CMUX_TAG"] == "t1")
        // Names that only look similar stay.
        #expect(TerminalEnvironment.isAllowed("CMUX_KEYBOARD_LAYOUT"))
    }

    @Test(.timeLimit(.minutes(1))) func capturesRealLoginShellEnvironment() async throws {
        let env = try #require(await LoginEnvironment.capture(timeout: .seconds(15)))
        #expect(env["PATH"]?.isEmpty == false)
        #expect(env["HOME"] == NSHomeDirectory())
    }

    @Test(.timeLimit(.minutes(1))) func processTimeoutKillsTheChild() async throws {
        await #expect(throws: DaemonError.self) {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                        environment: nil, timeout: .milliseconds(200), clock: ContinuousClock())
        }
    }
}
