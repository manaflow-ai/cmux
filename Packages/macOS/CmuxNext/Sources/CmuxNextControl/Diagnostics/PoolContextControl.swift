#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
public import CmuxNextWakeups
internal import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Darwin
import Dispatch
import Foundation

/// `debug.pool_context`: where the blocking detector places a seam call made from each kind of thread on this
/// macOS, and whether a raise reaches a running lane item's thread (plans/cmux-next/chrome-parity/p02-threads.md,
/// RUN-10, task 305). scripts/fuzz/macos-matrix/threads.py reads it in the macOS 14 and 15 Tart VMs
/// (`scripts/cmux-next/os-matrix.sh --suite threads`).
///
/// The detector tells the shared pool from a dedicated queue by libdispatch's queue label (`com.apple.root.`),
/// which is not API (risk 6), so each case reports the label it read next to the context it got. Each case makes
/// one checked seam call at its own line (`site`): a `Task.detached` and a `DispatchQueue.global` block (expected
/// `pool`, so `debug.blocking` lists the site as `pool`), a `.files` lane item (`lane`, not listed) and a `.cpu`
/// lane item (`cpu-lane`, listed as `wrong-lane`). Chrome makes the same split per task in `TaskTracker::RunTask`
/// (base/task/thread_pool/task_tracker.cc).
///
/// `raise` starts a best-effort `.system` item that waits on a pipe read, raises its handle to user-blocking while
/// it waits, then ends the read. The item reads its own thread before and after: the requested QoS
/// (`qos_class_self`, overrides excluded) and the kernel priority (`THREAD_EXTENDED_INFO` `pth_curpri`, overrides
/// included). The override works when the priority rises and the requested QoS stays utility (Chrome's
/// `ScopedBoostablePriority`, base/threading/scoped_thread_priority.h).
///
/// The pool and `.cpu` cases record real sites in the process's detector, so only a test run calls it, never a
/// sweep. With `CMUX_BLOCKING_TRAP_POOL=1` it refuses (the pool cases would stop the app).
public struct PoolContextControl: Sendable {
    /// One checked blocking call at `fileID`:`line` (tests bind their own violation table around it).
    typealias Seam = @Sendable (_ fileID: StaticString, _ line: UInt) -> Void

    /// What a case found on its thread.
    struct Observation: Sendable, Equatable {
        /// The detector's context for the thread; nil without the detector.
        var context: BlockingContext?
        /// The label of the queue the thread ran.
        var label: String
        /// The seam call's site, as `debug.blocking` names it.
        var site: String
    }

    /// One case: where it ran, the context it must get, and what it found.
    struct Case: Sendable, Equatable {
        var name: String
        var expected: BlockingContext
        var observed: Observation
    }

    /// A thread's requested QoS and kernel priority, read on that thread.
    struct ThreadReading: Sendable, Equatable {
        var qos: ThreadQoS
        var priority: Int32?

        /// The calling thread's reading.
        static func calling() -> ThreadReading {
            let info = MachThreads.info(pthread_mach_thread_np(pthread_self()), THREAD_EXTENDED_INFO,
                                        thread_extended_info_data_t())
            return ThreadReading(qos: DispatchQoS.QoSClass(rawValue: qos_class_self()).map { ThreadQoS($0) } ?? .unspecified,
                                 priority: info?.pth_curpri)
        }
    }

    /// The probe's errors.
    enum ProbeError: Error {
        /// The raised item did not start before the request ended.
        case raiseItemNotStarted
    }

    private let work: BackgroundWork
    private let detector: BlockingDetector
    private let seam: Seam

    /// Makes the method over the composition root's lanes and detector.
    public init(work: BackgroundWork, detector: BlockingDetector) {
        self.init(work: work, detector: detector) { fileID, line in
            _ = FileManager.checked.fileExists(atPath: "/", fileID: fileID, line: line)
        }
    }

    init(work: BackgroundWork, detector: BlockingDetector, seam: @escaping Seam) {
        self.work = work
        self.detector = detector
        self.seam = seam
    }

    /// The `debug.pool_context` control method.
    public var method: ControlMethod {
        .async("debug.pool_context") { [self] _ in try await report() }.withDeadline(.fixed(.seconds(10)))
    }

    /// The report: each case, then the raise.
    func report() async throws -> JSONValue {
        guard detector.poolMode != .trap else {
            return .object(["compiled_in": .bool(detector.isCompiledIn),
                            "refused": .string("CMUX_BLOCKING_TRAP_POOL=1: the pool cases would stop the app")])
        }
        let cases = try await runCases()
        let (before, after) = try await raiseRunningItem()
        return .object([
            "compiled_in": .bool(detector.isCompiledIn),
            "cases": .array(cases.map { item in
                .object([
                    "name": .string(item.name),
                    "expected": .string(item.expected.rawValue),
                    "context": item.observed.context.map { JSONValue.string($0.rawValue) } ?? .null,
                    "label": .string(item.observed.label),
                    "site": .string(item.observed.site),
                ])
            }),
            "raise": .object(["before": json(before), "after": json(after)]),
        ])
    }

    /// The four cases, one after another, each on its own kind of thread.
    func runCases() async throws -> [Case] {
        let seam = self.seam
        // qos-allow: the case is a detached task on the cooperative pool, the pool the detector must find.
        let detached = await Task.detached(priority: .medium) { Self.observe(seam) }.value
        let global = try await withOnceContinuation { (done: OnceContinuation<Observation, OnceContinuationError>) in
            // qos-allow: the case is a GCD root queue, the pool the detector must find.
            DispatchQueue.global(qos: .utility).async { _ = done.resume(returning: Self.observe(seam)) }
        }
        let files = try await work.run(.userVisible, mayBlock: .files) { Self.observe(seam) }
        let cpu = try await work.run(.userVisible, mayBlock: .cpu) { Self.observe(seam) }
        return [
            Case(name: "task_detached", expected: .pool, observed: detached),
            Case(name: "global_queue", expected: .pool, observed: global),
            Case(name: "lane_files", expected: .lane, observed: files),
            Case(name: "lane_cpu", expected: .cpuLane, observed: cpu),
        ]
    }

    /// Starts a best-effort `.system` item that waits on a pipe, raises it to user-blocking once it runs, then ends
    /// its read; the item's thread read before the raise and after it.
    func raiseRunningItem() async throws -> (before: ThreadReading, after: ThreadReading) {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let (started, starts) = AsyncStream.makeStream(of: ThreadReading.self, bufferingPolicy: .bufferingNewest(1))
        let handle = work.runHandle(.bestEffort, mayBlock: .system) { () throws -> ThreadReading in
            starts.yield(.calling())
            starts.finish()
            // A wait on a pipe is a lane's own kind of wait: the item holds its slot until the writer closes.
            _ = try reader.blockingRead(upToCount: 1)
            return .calling()
        }
        var readings = started.makeAsyncIterator()
        let before = await readings.next()
        if before != nil { handle.raise(to: .userBlocking) }
        // The end of the file ends the read, also when the request ends before the item started.
        try pipe.fileHandleForWriting.close()
        guard let before else {
            handle.cancel()
            throw ProbeError.raiseItemNotStarted
        }
        return (before, try await handle.value)
    }

    /// Classifies the calling thread and reads its queue label, then makes the seam call at the caller's line.
    private static func observe(_ seam: Seam, fileID: StaticString = #fileID, line: UInt = #line) -> Observation {
        let observation = Observation(context: BlockingContext.ofCallingThread(), label: BlockingContext.callingQueueLabel(),
                                      site: "\(fileID):\(line)")
        seam(fileID, line)
        return observation
    }

    private func json(_ reading: ThreadReading) -> JSONValue {
        .object(["qos": .string(reading.qos.rawValue), "priority": reading.priority.map { JSONValue.number(Double($0)) } ?? .null])
    }
}
#endif
