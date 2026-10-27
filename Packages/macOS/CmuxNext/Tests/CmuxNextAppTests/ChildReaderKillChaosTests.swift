import CmuxNextCloud
@testable import CmuxNextDiff
import CmuxNextRemote
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// p10-stability-168, chaos: each child-process reader that reads through
/// ``FileHandle/readAvailable(upToCount:fileID:line:)`` runs a real child that is SIGKILLed in the middle of its
/// output, and its owner reaches its own end state with every byte written before the kill: `SSHProcessRunner.run`
/// returns the kill status, `HostCLI.lines` and `ChildProcess.lines` finish, and the diff sidecar run fails with the
/// kill status. A reader whose end arm did not finish its latch, stream or reply would hang here until its deadline.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ChildReaderKillChaosTests {
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

    @Test func anSSHRunWhoseChildIsKilledDuringOutputReturnsTheKillStatusAndEveryByte() async throws {
        let result = try await SSHProcessRunner.run(["/bin/sh", "-c", Self.killedWriter], environment: [:],
                                                    deadline: .seconds(30), label: "killed writer")
        #expect(result.status == SIGKILL)
        #expect(result.stdout == Self.expectedOutput)
    }

    @Test func aHostCLIRunWhoseChildIsKilledDuringOutputFinishesItsLinesWithTheKillStatus() async throws {
        let cli = HostCLI(binary: URL(fileURLWithPath: "/bin/sh"), environment: { [:] })
        let lines = cli.lines(["-c", Self.killedWriter])
        let ended = try await withDeadline(.seconds(30), label: "host cli lines") { () async -> (Int, (any Error)?) in
            var count = 0
            do {
                for try await line in lines {
                    #expect(line == Self.line)
                    count += 1
                }
                return (count, nil)
            } catch {
                return (count, error)
            }
        }
        #expect(ended.0 == Self.linesBeforeKill)
        let stop = try #require(ended.1 as? HostCLIStop, "a killed run ends its lines with HostCLIStop")
        #expect(stop.status == SIGKILL)
    }

    @Test func aChildProcessKilledDuringOutputFinishesItsLinesAndReportsTheKill() async throws {
        let child = ChildProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", Self.killedWriter],
                                 environment: [:])
        try await child.start()
        defer { child.terminate() }
        let lines = child.lines
        let count = try await withDeadline(.seconds(30), label: "child lines") { () async -> Int in
            var count = 0
            for await line in lines {
                #expect(line == Self.line)
                count += 1
            }
            return count
        }
        #expect(count == Self.linesBeforeKill)
        #expect(await child.waitForExit() == SIGKILL)
    }

    /// A stand-in sidecar: it prints the ready marker, reads the request to its end, then writes its reply and is
    /// killed halfway. Both readers (reply and stderr) end; the exit status decides.
    @Test func aDiffSidecarKilledDuringItsReplyFailsWithTheKillStatus() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-killed-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sidecar = folder.appendingPathComponent("sidecar")
        let script = "#!/bin/sh\nprintf 'cmux-diff-sidecar-process-group-ready\\n' >&2\nwhile read -r request; do :; done\n"
            + Self.killedWriter + "\n"
        try script.write(to: sidecar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sidecar.path)
        let launcher = CmuxNextWakeups.ProcessLauncher(label: "test.killed-diff-sidecar", priority: .userVisible)
        let limits = DiffSidecarProcess.Limits(startup: .seconds(20), request: .seconds(30))
        await #expect(throws: DiffSidecarError.failed(status: SIGKILL)) {
            _ = try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data("{\"op\":\"ping\"}\n".utf8),
                                                 launcher: launcher, limits: limits)
        }
    }
}
