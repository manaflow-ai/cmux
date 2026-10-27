import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// p10-stability-168, chaos: the agent pane's child-process readers read through
/// ``FileHandle/readAvailable(upToCount:fileID:line:)``. Each runs a real child that is SIGKILLed in the middle of
/// its output, and its owner reaches its own end state with every byte written before the kill: a shell command
/// reports its signal, a completion shell answers its output, and the line reader throws `endOfFile`. A reader
/// whose end arm did not close its run, finish its completion or resume its line would hang here. A failed
/// `read(2)` (the case the legacy read raised on) maps to ``AgentPaneLineReader/Failure/unreadable(errno:)``.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentPaneReaderKillChaosTests {
    /// One line the child writes: 1 KiB with its newline.
    nonisolated static let line = String(repeating: "x", count: 1023)
    /// The lines written before the kill: 200 KiB, past the 64 KiB pipe buffer, so the child's writes wait on the
    /// reader and the kill lands while unread output is still in the pipe.
    nonisolated static let linesBeforeKill = 200
    nonisolated static var expectedOutput: String { String(repeating: line + "\n", count: linesBeforeKill) }

    /// A shell loop that would write twice as many lines but kills itself (SIGKILL, no handler, no flush) halfway.
    nonisolated static var killedWriter: String {
        "line=\(line); i=0; while [ \"$i\" -lt \(linesBeforeKill * 2) ]; do "
            + "[ \"$i\" -eq \(linesBeforeKill) ] && kill -KILL $$; printf '%s\\n' \"$line\"; i=$((i + 1)); done; "
            + "printf 'survived the kill\\n'"
    }

    @Test func aShellCommandKilledDuringOutputReportsItsSignalAfterEveryByte() async throws {
        let shell = AgentPaneShell(shell: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"], home: NSTemporaryDirectory(),
                                   deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
        defer { shell.terminateAll() }
        let id = try await shell.run(Self.killedWriter, cwd: nil)
        var output = ""
        var next = 0
        var exit: AgentPaneShell.Exit?
        // Each read answers once there is news; the exit comes only after the reader's end closed the output.
        while exit == nil {
            let chunk = try await shell.read(id, after: next)
            output += chunk.output
            next = chunk.next
            exit = chunk.exit
        }
        #expect(exit == AgentPaneShell.Exit(signal: SIGKILL))
        #expect(output == Self.expectedOutput)
    }

    @Test func aCompletionShellKilledDuringOutputAnswersEveryByte() async throws {
        let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.test-killed-complete", priority: .userBlocking)
        let output = try await CompletionProcess.run(path: "/bin/sh", arguments: ["/bin/sh", "-c", Self.killedWriter],
                                                     environment: ["PATH": "/usr/bin:/bin"], folder: NSTemporaryDirectory(),
                                                     timeout: .seconds(30), launcher: launcher)
        #expect(String(decoding: output, as: UTF8.self) == Self.expectedOutput)
    }

    /// The child is killed halfway through a line (it would end the line after the loop): the reader's end is `endOfFile`.
    @Test func aLineReaderWhoseChildIsKilledBeforeALineThrowsEndOfFile() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let partialLine = "i=0; while [ \"$i\" -lt 128 ]; do [ \"$i\" -eq 64 ] && kill -KILL $$; printf 'partial'; "
            + "i=$((i + 1)); done; printf '\\n'"
        process.arguments = ["-c", partialLine]
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let reader = AgentPaneLineReader(handle: stdout.fileHandleForReading)
        try process.run()
        await #expect(throws: AgentPaneLineReader.Failure.endOfFile) { _ = try await reader.firstLine() }
    }

    /// A failed `read(2)`, as the readability handler delivers it, ends the read with its errno: not `endOfFile`, and
    /// not a line from the bytes before it. The pipe stays open, so no end of file races it.
    @Test func aFailedReadThrowsUnreadableWithItsErrno() async {
        let pipe = Pipe()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        reader.receive(.bytes(Data("no newline yet".utf8)))
        reader.receive(.end(.failed(errno: EIO)))
        await #expect(throws: AgentPaneLineReader.Failure.unreadable(errno: EIO)) { _ = try await reader.firstLine() }
        withExtendedLifetime(pipe) {}
    }
}
