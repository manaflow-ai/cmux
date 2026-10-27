@testable import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing

/// Child processes start off the main thread at a stated priority (plans/cmux-next/chrome-parity/p02-threads.md,
/// task 037): ``ChildProcessLauncher`` runs each spawn on its owner's serial queue at its ``MayBlockPriority``,
/// and ``blockingPosixSpawn(_:_:_:_:_:_:priority:fileID:line:)`` clamps a best-effort or idle child. Each test
/// binds its own table (``BlockingViolationTable/scoped``); every child is reaped.
@Suite(.serialized)
struct ChildProcessLauncherTests {
    /// A launcher of the tests' own.
    private static func launcher(_ priority: MayBlockPriority) -> ChildProcessLauncher {
        ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.tests", priority: priority)
    }

    /// Only best effort and idle are clamps (`posix_spawnattr_set_qos_class_np` refuses the higher classes with
    /// EINVAL), and no launcher runs at user-interactive.
    @Test func eachPriorityMapsToItsClamp() {
        #expect(MayBlockPriority.allCases.map(\.spawnClamp) == [QOS_CLASS_BACKGROUND, QOS_CLASS_UTILITY, nil, nil])
        #expect(MayBlockPriority.allCases.allSatisfy { $0.qos.qosClass != .userInteractive })
    }

    /// Each item runs on the launcher's queue at its priority's QoS, never on the caller's (main) thread.
    @MainActor @Test(arguments: MayBlockPriority.allCases)
    func aSpawnItemRunsOffTheCallerOnTheLauncherQueue(priority: MayBlockPriority) async {
        let seen = await Self.launcher(priority).run { () -> Seen in
            Seen(onMain: pthread_main_np() != 0, queue: String(cString: __dispatch_queue_get_label(nil)),
                 qos: qos_class_self())
        }
        #expect(!seen.onMain)
        #expect(seen.queue == "com.cmuxterm.next.child-launcher.tests")
        #expect(seen.qos == priority.qos.qosClass.rawValue)
    }

    /// A launcher is one sequence (Chrome's launcher sequence): a posted spawn and an awaited one run in call order.
    @Test func aLauncherRunsItsSpawnsInCallOrder() async {
        let (order, launcher) = (Order(), Self.launcher(.userVisible))
        launcher.post { order.append(1) }
        let seen = await launcher.run { () -> [Int] in
            order.append(2)
            return order.entries
        }
        #expect(seen == [1, 2])
    }

    /// A spawn's typed error comes back to the awaiting caller as itself.
    @Test func aSpawnFailureReachesTheCaller() async {
        do throws(SpawnFailure) {
            _ = try await Self.launcher(.bestEffort).run { () throws(SpawnFailure) -> Int32 in
                throw SpawnFailure(code: ENOENT)
            }
            Issue.record("the spawn item's error was lost")
        } catch {
            #expect(error == SpawnFailure(code: ENOENT))
        }
    }

    /// The seam sets the clamp on the caller's attributes for best effort and idle, and leaves them alone above.
    @Test(arguments: MayBlockPriority.allCases)
    func theSeamClampsOnlyBestEffortAndIdleChildren(priority: MayBlockPriority) throws {
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        let spawned = BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .record)) {
            spawnChild(["/usr/bin/true"], attributes: &attributes, priority: priority)
        }
        try #require(spawned.status == 0)
        reap(spawned.pid)
        var clamp = QOS_CLASS_UNSPECIFIED
        try #require(posix_spawnattr_get_qos_class_np(&attributes, &clamp) == 0)
        #expect(clamp == (priority.spawnClamp ?? QOS_CLASS_UNSPECIFIED))
    }

    /// Nil attributes spawn with the seam's own, which carry only the clamp.
    @Test func theSeamSpawnsWithItsOwnAttributesWhenGivenNone() throws {
        let spawned = BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .record)) {
            spawnChild(["/usr/bin/true"], attributes: nil, priority: .idle)
        }
        try #require(spawned.status == 0)
        #expect(reap(spawned.pid) == 0)
    }

    /// What the child itself reports. A clamped child runs at or below its clamp. An unclamped child reports
    /// the same QoS whether the launcher (user-initiated or default) or the main thread (user-interactive)
    /// spawned it: the spawning thread's QoS does not reach the child, so the higher priorities set only how
    /// fast the spawn runs (ChildProcessLauncher's contract). If this fails, Darwin passes the spawning
    /// thread's QoS on and that contract must say so.
    @MainActor @Test(arguments: MayBlockPriority.allCases)
    func aChildReportsTheQoSItsPriorityGivesIt(priority: MayBlockPriority) async throws {
        let launcher = Self.launcher(priority)
        let fromLauncher = await launcher.run { () -> SpawnedChild in
            BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .record)) { spawnQoSProbe(priority: priority) }
        }
        let fromMain = BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .record)) {
            spawnQoSProbe(priority: priority)
        }
        let reported = await Self.launcher(.userBlocking).run { () -> [UInt32?] in
            [collectQoS(fromLauncher), collectQoS(fromMain)]
        }
        let launched = try #require(reported[0])
        let inline = try #require(reported[1])
        if let clamp = priority.spawnClamp {
            #expect(launched <= clamp.rawValue)
            #expect(inline <= clamp.rawValue)
        } else {
            #expect(launched == inline)
        }
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The acceptance of task 037: from main-actor code, a spawn through a launcher records no main-thread
    /// site, and the same spawn inline records one.
    @MainActor @Test func aSpawnThroughTheLauncherRecordsNoMainViolation() async throws {
        let table = BlockingViolationTable(mode: .record)
        let launcher = Self.launcher(.userBlocking)
        let queued = await launcher.run { () -> SpawnedChild in
            // A dispatch block does not inherit task-locals: bind the test's table on the queue's thread.
            BlockingViolationTable.$scoped.withValue(table) {
                spawnChild(["/usr/bin/true"], attributes: nil, priority: launcher.priority)
            }
        }
        try #require(queued.status == 0)
        reap(queued.pid)
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)

        let inline = BlockingViolationTable.$scoped.withValue(table) {
            spawnChild(["/usr/bin/true"], attributes: nil, priority: .userBlocking)
        }
        try #require(inline.status == 0)
        reap(inline.pid)
        await table.flush()
        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.processSpawn])
    }
    #endif
}

/// What a spawn item saw of its thread.
private nonisolated struct Seen: Sendable {
    let onMain: Bool
    let queue: String
    let qos: qos_class_t
}

private nonisolated struct SpawnFailure: Error, Equatable {
    let code: Int32
}

/// The order in which launcher items ran.
private nonisolated final class Order: Sendable {
    private let state = Mutex<[Int]>([])
    func append(_ value: Int) { state.withLock { $0.append(value) } }
    var entries: [Int] { state.withLock { $0 } }
}

/// A spawn's status and, when it is 0, the child's pid and the read end of its stdout (-1 for none).
private nonisolated struct SpawnedChild: Sendable {
    let status: Int32
    let pid: pid_t
    var output: Int32 = -1
}

/// Starts `argv` through the QoS seam, its stdout into a pipe when `capture`.
private nonisolated func spawnChild(_ arguments: [String], attributes: UnsafeMutablePointer<posix_spawnattr_t?>?,
                                    priority: MayBlockPriority, capture: Bool = false) -> SpawnedChild {
    var ends: [Int32] = [-1, -1]
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if capture {
        guard pipe(&ends) == 0 else { return SpawnedChild(status: errno, pid: 0) }
        posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, ends[0])
    }
    var pid: pid_t = 0
    let argv = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let status = blockingPosixSpawn(&pid, arguments[0], &actions, attributes, argv, environ, priority: priority)
    if capture { close(ends[1]) }
    guard status == 0 else {
        if capture { close(ends[0]) }
        return SpawnedChild(status: status, pid: 0)
    }
    return SpawnedChild(status: 0, pid: pid, output: ends[0])
}

/// Starts a child that prints the QoS class of its own thread (`qos_class_self()`), then exits.
private nonisolated func spawnQoSProbe(priority: MayBlockPriority) -> SpawnedChild {
    let script = "import ctypes; print(ctypes.CDLL('/usr/lib/libSystem.B.dylib').qos_class_self())"
    return spawnChild(["/usr/bin/python3", "-c", script], attributes: nil, priority: priority, capture: true)
}

/// Reads what a QoS probe printed and reaps it; nil when it did not start, printed no class or failed.
private nonisolated func collectQoS(_ child: SpawnedChild) -> UInt32? {
    guard child.status == 0 else { return nil }
    let handle = FileHandle(fileDescriptor: child.output, closeOnDealloc: true)
    let printed = try? handle.blockingReadToEnd()
    let code = reap(child.pid)
    guard code == 0, let printed else { return nil }
    return UInt32(String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Reaps `pid` and returns its exit code.
@discardableResult
private nonisolated func reap(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    return (status >> 8) & 0xFF
}
