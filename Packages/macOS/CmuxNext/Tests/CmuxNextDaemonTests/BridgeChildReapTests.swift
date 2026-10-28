#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
@testable import CmuxNextDaemon
import Darwin
import Dispatch
import Foundation
import Testing

/// A bridge child is killed where its last reference drops, often the main thread when a connection closes, and
/// reaped on the bridge's reap queue from a process-exit source. It used to `waitpid` for the
/// child inside its lock on the dropping thread.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BridgeChildReapTests {
    @MainActor @Test func droppingABridgeChildOnTheMainThreadRecordsNothingAndReapsItOnTheReapQueue() async throws {
        let pid = try Self.spawn()
        let errorPipe = try Self.pipeReadEnd()
        let reaper = DispatchQueue(label: "cmux.next.daemon.test-bridge-reap.\(pid)", qos: .utility)
        // Held, so a reap on the dropping thread is the only way the child could be reaped before the resume.
        reaper.suspend()
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            var child: BridgeChild? = BridgeChild(pid: pid, stderr: errorPipe, reaper: reaper)
            #expect(child?.pid == pid)
            child = nil
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty, "dropping a bridge child recorded a main-thread wait")

        #expect(Self.exitedButNotReaped(pid), "the child was killed, and the dropping thread did not reap it")
        reaper.resume()
        await Self.drain(reaper)
        #expect(Self.isReaped(pid), "the reap queue reaped the child once it ran")
    }

    @Test func terminatingTwiceKillsAndReapsOnce() async throws {
        let pid = try Self.spawn()
        let reaper = DispatchQueue(label: "cmux.next.daemon.test-bridge-reap.\(pid)", qos: .utility)
        let child = BridgeChild(pid: pid, stderr: try Self.pipeReadEnd(), reaper: reaper)
        reaper.suspend()
        child.terminate()
        #expect(Self.exitedButNotReaped(pid), "terminate killed the child and returned before its reap")
        reaper.resume()
        await Self.drain(reaper)
        #expect(Self.isReaped(pid))
        // The second call (and the deinit after it) finds the descriptor handed off and does nothing.
        child.terminate()
        await Self.drain(reaper)
    }

    /// Whether the child ended and is a zombie still: `WNOWAIT` leaves it for its reaper.
    private static func exitedButNotReaped(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 && info.si_pid == pid
    }

    private static func isReaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }

    /// Runs after everything queued on `queue` so far: a watch started on a child that already exited reaps it
    /// in the item it queued at its start.
    private static func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    nonisolated private struct SetupFailed: Error { let code: Int32 }

    /// A pipe's read end for the child's stderr (``BridgeChild`` closes it); the write end is closed at once.
    private static func pipeReadEnd() throws -> Int32 {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw SetupFailed(code: errno) }
        close(ends[1])
        return ends[0]
    }

    private static func spawn() throws -> pid_t {
        let arguments = cStrings(["/bin/sleep", "30"])
        let environment = cStrings(["PATH=/usr/bin:/bin"])
        defer { for pointer in arguments + environment { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, environment)
        guard result == 0 else { throw SetupFailed(code: result) }
        return pid
    }

    /// `strings` as C strings for `posix_spawn`, ending with nil; the caller frees each one. Typed, so the
    /// literals are not taken for `UnsafePointer<CChar>` arguments.
    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }
}
#endif
