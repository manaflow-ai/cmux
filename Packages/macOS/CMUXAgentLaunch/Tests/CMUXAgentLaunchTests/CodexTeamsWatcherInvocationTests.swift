import Testing
@testable import CMUXAgentLaunch

@Suite("Codex Teams watcher invocation")
struct CodexTeamsWatcherInvocationTests {
    private func makeInvocation(
        socketPassword: String?,
        environment: [String: String] = ["PATH": "/usr/bin:/bin"]
    ) -> CodexTeamsWatcherInvocation {
        CodexTeamsWatcherInvocation(
            socketPath: "/tmp/cmux-watcher-test.sock",
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            appServerURL: "ws://127.0.0.1:4500",
            codexPath: "/usr/local/bin/codex",
            launchPath: "/usr/local/bin:/usr/bin",
            maxAutoDepth: 2,
            ownerPID: 4242,
            socketPassword: socketPassword,
            environment: environment
        )
    }

    @Test("The socket password reaches the watcher through its environment, never its arguments")
    func socketPasswordStaysOutOfArguments() {
        let password = "watcher-socket-password"
        let invocation = makeInvocation(socketPassword: password)

        #expect(!invocation.arguments.contains { $0.contains(password) })
        #expect(!invocation.arguments.contains("--password"))
        #expect(invocation.environment["CMUX_SOCKET_PASSWORD"] == password)
        #expect(invocation.environment["PATH"] == "/usr/bin:/bin")
    }

    @Test("The watcher keeps its socket, identity and owner flags")
    func argumentsKeepWatcherFlags() {
        let invocation = makeInvocation(socketPassword: nil)

        #expect(invocation.arguments == [
            "--socket", "/tmp/cmux-watcher-test.sock",
            "__codex-teams-watch",
            "--workspace-id", "workspace-1",
            "--surface-id", "surface-1",
            "--app-server-url", "ws://127.0.0.1:4500",
            "--codex-path", "/usr/local/bin/codex",
            "--launch-path", "/usr/local/bin:/usr/bin",
            "--max-auto-depth", "2",
            "--owner-pid", "4242",
        ])
        #expect(invocation.environment == ["PATH": "/usr/bin:/bin"])
    }
}
