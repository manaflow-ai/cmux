import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing

/// ``ChildExitWatch`` reaps a child from a process-exit source on its own named queue, with no thread parked in
/// `waitpid` while the child runs: the shell-mode and Tab-completion shells used to hold a GCD
/// root-queue thread each for their whole run.
@Suite(.serialized)
struct ChildExitWatchTests {
    @Test func aRunningChildIsReapedWithItsStatusOnItsOwnQueue() async throws {
        let pid = try Self.spawn("sleep 0.2; exit 3")
        let (status, label) = await Self.exit(of: pid)
        #expect(status.map { ($0 >> 8) & 0xff } == 3, "the exit code reaches the callback")
        #expect(label == "cmux.next.compat.test-reap.\(pid)", "the callback runs on the child's named queue, not a root queue")
        #expect(Self.isReaped(pid), "no zombie is left")
    }

    @Test func aChildThatExitedBeforeTheWatchStartedIsReaped() async throws {
        let pid = try Self.spawn("exit 5")
        // Wait for the exit without reaping it: the child is a zombie before the source is armed.
        var info = siginfo_t()
        #expect(waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0)
        let (status, _) = await Self.exit(of: pid)
        #expect(status.map { ($0 >> 8) & 0xff } == 5)
        #expect(Self.isReaped(pid))
    }

    @Test func aChildSomeoneElseReapedAnswersNoStatus() async throws {
        let pid = try Self.spawn("exit 0")
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        let (answer, _) = await Self.exit(of: pid)
        #expect(answer == nil, "ECHILD: the status is unknown")
    }

    @Test func aKilledChildReportsItsSignal() async throws {
        let pid = try Self.spawn("sleep 30")
        let exited = Task { await Self.exit(of: pid) }
        kill(pid, SIGKILL)
        let (status, _) = await exited.value
        #expect(status.map { $0 & 0x7f } == SIGKILL)
        #expect(Self.isReaped(pid))
    }

    /// The claim itself: while the child runs, its reap queue is free. A watch that waited in a blocking
    /// `waitpid` on the queue would hold this probe until the child's 30 s end.
    @Test func noThreadWaitsOnTheReapQueueWhileTheChildRuns() async throws {
        let pid = try Self.spawn("sleep 30")
        let queue = DispatchQueue(label: "cmux.next.compat.test-reap.\(pid)", qos: .utility)
        let (statuses, sink) = AsyncStream.makeStream(of: Int32?.self, bufferingPolicy: .bufferingNewest(1))
        // Started here, before the probe is queued: whatever the watch queues runs first.
        ChildExitWatch(pid: pid, queue: queue).start { status in
            sink.yield(status)
            sink.finish()
        }
        let probe = DispatchSemaphore(value: 0)
        queue.async { probe.signal() }
        let free = await Self.wait(probe, timeout: .seconds(5))
        #expect(free, "the reap queue ran other work while the child (30 s) was alive")
        kill(pid, SIGKILL)
        var exits = statuses.makeAsyncIterator()
        let status = await exits.next()
        #expect(status.flatMap { $0 }.map { $0 & 0x7f } == SIGKILL)
        #expect(Self.isReaped(pid))
    }

    /// Waits for `semaphore` off the cooperative pool, at most `timeout`.
    private static func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "cmux.next.compat.test-wait", qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    private static func exit(of pid: pid_t) async -> (Int32?, String) {
        await withCheckedContinuation { continuation in
            ChildExitWatch(pid: pid, queue: DispatchQueue(label: "cmux.next.compat.test-reap.\(pid)", qos: .utility)).start { status in
                continuation.resume(returning: (status, String(cString: __dispatch_queue_get_label(nil))))
            }
        }
    }

    private static func isReaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }

    nonisolated private struct SpawnFailed: Error { let code: Int32 }

    private static func spawn(_ script: String) throws -> pid_t {
        let words: [String] = ["/bin/sh", "-c", script]
        let variables: [String] = ["PATH=/usr/bin:/bin"]
        let arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer { for pointer in arguments + environment { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", nil, nil, arguments, environment)
        guard result == 0 else { throw SpawnFailed(code: result) }
        return pid
    }
}
