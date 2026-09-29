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

    @Test func daemonEnvironmentDropsIdentityKeysAndAppliesOverrides() {
        let env = LoginEnvironment.daemonEnvironment(
            login: ["PATH": "/opt/homebrew/bin:/usr/bin", "CMUX_TUI_SOCKET": "/tmp/leak", "SHLVL": "2", "EDITOR": "vim"],
            base: [:],
            overrides: ["CMUX_TUI_STATE_DIR": "/tmp/state"])
        #expect(env["CMUX_TUI_SOCKET"] == nil)
        #expect(env["SHLVL"] == nil)
        #expect(env["EDITOR"] == "vim")
        #expect(env["CMUX_TUI_STATE_DIR"] == "/tmp/state")

        let fallback = LoginEnvironment.daemonEnvironment(login: nil, base: ["PATH": "/usr/bin:/bin"], overrides: [:])
        #expect(fallback["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
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
