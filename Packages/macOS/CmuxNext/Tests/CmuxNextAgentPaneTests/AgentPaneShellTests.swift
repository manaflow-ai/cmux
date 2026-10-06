import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Shell mode's host side: commands run in the chat's folder, stream back through `shell.read`,
/// stop with their process group, and run only after a real gesture in the pane.
@MainActor
@Suite struct AgentPaneShellTests {
    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    /// Reads until the command ends, as the page does.
    private func drain(_ shell: AgentPaneShell, _ id: String) async throws -> (String, AgentPaneShell.Exit) {
        var output = ""
        var after = 0
        for _ in 0..<50 {
            let chunk = try await shell.read(id, after: after)
            output += chunk.output
            after = chunk.next
            if let exit = chunk.exit { return (output, exit) }
        }
        Issue.record("the command did not end")
        return (output, AgentPaneShell.Exit())
    }

    @Test func aCommandRunsInTheChatsFolderAndItsOutputStreamsBack() async throws {
        let shell = AgentPaneShell(shell: "/bin/sh")
        let cwd = try folder()
        let id = try shell.run("pwd; printf 'a\\nb\\n'; echo oops >&2", cwd: cwd)
        let (output, exit) = try await drain(shell, id)
        #expect(output == "\(cwd)\na\nb\noops\n")
        #expect(exit == AgentPaneShell.Exit(code: 0))
    }

    @Test func aFailingCommandReportsItsExitCode() async throws {
        let shell = AgentPaneShell(shell: "/bin/sh")
        let (_, exit) = try await drain(shell, try shell.run("exit 3", cwd: try folder()))
        #expect(exit == AgentPaneShell.Exit(code: 3))
    }

    /// Ctrl-C reaches what the command started, not only the shell.
    @Test func stopInterruptsTheCommandsProcessGroup() async throws {
        let shell = AgentPaneShell(shell: "/bin/sh")
        let id = try shell.run("sleep 30 & wait", cwd: try folder())
        let started = ContinuousClock.now
        shell.stop(id)
        let (_, exit) = try await drain(shell, id)
        #expect(exit.code == nil || exit.code != 0)
        #expect(ContinuousClock.now - started < .seconds(8))
    }

    @Test func aMissingFolderIsRefusedAndRunsNothing() throws {
        let shell = AgentPaneShell(shell: "/bin/sh")
        #expect(throws: AgentPaneShell.Failure.folderMissing) {
            try shell.run("touch should-not-exist", cwd: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func atMostFourCommandsRunAtOnce() throws {
        let shell = AgentPaneShell(shell: "/bin/sh")
        let cwd = try folder()
        let ids = try (0..<AgentPaneShell.maximumRunning).map { _ in try shell.run("sleep 30", cwd: cwd) }
        #expect(throws: AgentPaneShell.Failure.tooMany) { try shell.run("true", cwd: cwd) }
        for id in ids { shell.stop(id) }
        shell.terminateAll()
    }

    /// A read never splits a character, so the page never shows a replacement glyph mid-stream.
    @Test func aReadEndsOnAWholeCharacter() {
        let snowman = Data("a☃".utf8)
        #expect(AgentPaneShell.utf8Complete(snowman) == snowman.count)
        #expect(AgentPaneShell.utf8Complete(snowman.prefix(2)) == 1)
        #expect(AgentPaneShell.utf8Complete(snowman.prefix(3)) == 1)
        #expect(AgentPaneShell.utf8Complete(Data("abc".utf8)) == 3)
    }

    @Test func theWaitStatusBecomesAnExitCodeOrASignal() {
        #expect(AgentPaneShell.exit(status: 3 << 8) == AgentPaneShell.Exit(code: 3))
        #expect(AgentPaneShell.exit(status: SIGINT) == AgentPaneShell.Exit(signal: SIGINT))
    }

    @Test func requestsDecodeOnlyWithACommandAndAnAbsoluteFolder() {
        func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
            AgentPaneRequest(body: ["method": method, "params": params] as [String: Any])
        }
        #expect(request("shell.run", ["command": "ls", "cwd": "/repo"]) == .shellRun(command: "ls", cwd: "/repo"))
        #expect(request("shell.run", ["command": "ls", "cwd": "repo"]) == .shellRun(command: "ls", cwd: nil))
        #expect(request("shell.run", ["command": "  "]) == .unsupported("shell.run"))
        #expect(request("shell.read", ["id": "r1", "after": 12]) == .shellRead(id: "r1", after: 12))
        #expect(request("shell.read", ["id": "r1", "after": -1]) == .unsupported("shell.read"))
        #expect(request("shell.stop", ["id": "r1"]) == .shellStop(id: "r1"))
        #expect(request("shell.run", ["command": "ls"]).isShell)
    }

    /// Page script cannot run a command: `shell.run` needs the user's own key press or click.
    @Test func aCommandRunsOnlyAfterAGestureInThePane() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let cwd = try folder()
        let refused = await model.respond(to: .shellRun(command: "touch ran", cwd: cwd))
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "shell.gesture_required")
        #expect(!FileManager.default.fileExists(atPath: cwd + "/ran"))
        model.transport.gestures.record()
        let started = await model.respond(to: .shellRun(command: "true", cwd: cwd))
        #expect((started["value"] as? [String: Any])?["id"] is String)
        // One gesture runs one command.
        let again = await model.respond(to: .shellRun(command: "true", cwd: cwd))
        #expect((again["error"] as? [String: Any])?["code"] as? String == "shell.gesture_required")
    }
}
