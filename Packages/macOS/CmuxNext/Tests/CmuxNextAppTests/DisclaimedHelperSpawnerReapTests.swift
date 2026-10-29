import Darwin
import Dispatch
import Foundation
import Testing
@testable import CmuxNextComputerUse

/// The Computer Use helper is reaped from a process-exit source on the spawner's reap queue,
/// where a `cua-helper-v2-reap` thread used to wait in `waitpid` for as long as the helper ran on after SIGTERM.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DisclaimedHelperSpawnerReapTests {
    @MainActor @Test func terminateReturnsAtOnceAndTheReapQueueReapsTheHelper() async throws {
        let pid = try Self.spawn()
        let reaper = DispatchQueue(label: "cmux.next.computer-use.test-helper-reap.\(pid)", qos: .utility)
        let spawner = DisclaimedHelperSpawner(disclaim: nil, reaper: reaper)
        reaper.suspend()
        spawner.terminate(pid)
        #expect(Self.exitedButNotReaped(pid), "SIGTERM ended the helper, and terminate did not reap it itself")
        reaper.resume()
        await Self.drain(reaper)
        #expect(Self.isReaped(pid), "the reap queue reaped the helper")
    }

    @Test func aHelperThatOutlivesSIGTERMHoldsNoThreadOnTheReapQueue() async throws {
        let pid = try Self.spawn(ignoringTerm: true)
        let reaper = DispatchQueue(label: "cmux.next.computer-use.test-helper-reap.\(pid)", qos: .utility)
        DisclaimedHelperSpawner(disclaim: nil, reaper: reaper).terminate(pid)
        // A watch that waited in `waitpid` on the queue would hold this item until the helper's end.
        await Self.drain(reaper)
        #expect(kill(pid, 0) == 0, "the helper ignores SIGTERM and still runs")
        kill(pid, SIGKILL)
        #expect(Self.exitedButNotReaped(pid) || Self.isReaped(pid))
    }

    @Test func closingInputTwiceClosesItOnce() {
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        let child = ComputerUseHelperV2Child(pid: 0, input: ends[1], lines: AsyncStream { $0.finish() })
        child.closeInput()
        child.closeInput()
        var byte: UInt8 = 0
        #expect(read(ends[0], &byte, 1) == 0, "the write end is closed: the reader sees EOF")
        close(ends[0])
    }

    private static func exitedButNotReaped(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 && info.si_pid == pid
    }

    private static func isReaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }

    private static func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    nonisolated private struct SpawnFailed: Error { let code: Int32 }

    /// Starts `sleep 30` under `/bin/sh`; with `ignoringTerm`, SIGTERM is ignored first and the spawn returns once
    /// the shell says so, so the test's SIGTERM never lands before the `trap`.
    private static func spawn(ignoringTerm: Bool = false) throws -> pid_t {
        let script = ignoringTerm ? "trap '' TERM; echo ready; exec sleep 30" : "exec sleep 30"
        var ready: [Int32] = [-1, -1]
        guard pipe(&ready) == 0 else { throw SpawnFailed(code: errno) }
        defer { close(ready[0]) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, ready[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, ready[0])
        // The strings are typed [String]: untyped, the literals are taken for strdup's UnsafePointer<CChar>.
        let argumentStrings: [String] = ["/bin/sh", "-c", script], environmentStrings: [String] = ["PATH=/usr/bin:/bin"]
        let arguments = argumentStrings.map { strdup($0) } + [nil]
        let environment = environmentStrings.map { strdup($0) } + [nil]
        defer { for pointer in arguments + environment { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", &actions, nil, arguments, environment)
        close(ready[1])
        guard result == 0 else { throw SpawnFailed(code: result) }
        if ignoringTerm {
            var byte: UInt8 = 0
            guard read(ready[0], &byte, 1) == 1 else { throw SpawnFailed(code: errno) }
        }
        return pid
    }
}
