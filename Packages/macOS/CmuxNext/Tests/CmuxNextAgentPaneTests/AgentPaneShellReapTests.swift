import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Shell mode's commands and its Tab completions are reaped through ``ChildExitWatch``: a
/// command's exit code reaches its read, and a completion shell answers once it was reaped and its pipe closed.
/// Without the reap neither ever ends: the read reports no exit and the completion times out.
@MainActor @Suite(.serialized)
struct AgentPaneShellReapTests {
    @Test func aCommandsExitCodeReachesItsRead() async throws {
        let shell = AgentPaneShell(shell: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], home: NSTemporaryDirectory())
        defer { shell.terminateAll() }
        let id = try await shell.run("exit 7", cwd: nil)
        var chunk = try await shell.read(id, after: 0)
        var reads = 1
        while chunk.exit == nil, reads < 3 {
            chunk = try await shell.read(id, after: chunk.next)
            reads += 1
        }
        #expect(chunk.exit == AgentPaneShell.Exit(code: 7))
    }

    @Test func aCompletionShellAnswersOnceItIsReaped() async throws {
        let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.test-complete", priority: .userBlocking)
        let output = try await CompletionProcess.run(path: "/bin/sh", arguments: ["/bin/sh", "-c", "printf done"],
                                                     environment: ["PATH": "/usr/bin:/bin"], folder: NSTemporaryDirectory(),
                                                     timeout: .seconds(10), launcher: launcher)
        #expect(String(decoding: output, as: UTF8.self) == "done")
    }
}
