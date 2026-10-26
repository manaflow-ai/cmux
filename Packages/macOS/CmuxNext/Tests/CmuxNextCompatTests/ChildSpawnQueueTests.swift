@testable import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing

/// Child processes start off the main thread at a stated QoS (plans/cmux-next/chrome-parity/p02-threads.md,
/// task 037): ``ChildSpawnQueue`` runs each spawn on its own named serial queue at the children's QoS, and
/// ``blockingPosixSpawn(_:_:_:_:_:_:qos:fileID:line:)`` clamps a utility or background child. Each test binds
/// its own table (``BlockingViolationTable/scoped``); the only child is `/usr/bin/true`, reaped.
@Suite(.serialized)
struct ChildSpawnQueueTests {
    /// The process-roles column: no child above userInitiated, and only utility and background are clamps
    /// (`posix_spawnattr_set_qos_class_np` refuses the rest with EINVAL).
    @Test func eachChildQoSMapsToItsClassAndClamp() {
        #expect(ChildProcessQoS.allCases.map(\.qosClass)
            == [QOS_CLASS_USER_INITIATED, QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY, QOS_CLASS_BACKGROUND])
        #expect(ChildProcessQoS.allCases.map(\.spawnClamp)
            == [nil, nil, QOS_CLASS_UTILITY, QOS_CLASS_BACKGROUND])
        #expect(ChildProcessQoS.allCases.allSatisfy { $0.dispatchQoS.qosClass != .userInteractive })
    }

    /// Each item runs on the queue's own thread at the queue's QoS, never on the caller's (main) thread.
    @MainActor @Test(arguments: ChildProcessQoS.allCases)
    func aSpawnItemRunsOffTheCallerAtTheChildQoS(qos: ChildProcessQoS) async {
        let spawns = ChildSpawnQueue(label: "com.cmuxterm.tests.child-spawn", qos: qos)
        let seen = await spawns.run { () -> Seen in
            Seen(onMain: pthread_main_np() != 0, queue: String(cString: __dispatch_queue_get_label(nil)),
                 qos: qos_class_self())
        }
        #expect(!seen.onMain)
        #expect(seen.queue == "com.cmuxterm.tests.child-spawn")
        #expect(seen.qos == qos.qosClass)
    }

    /// A spawn's typed error comes back to the awaiting caller as itself.
    @Test func aSpawnFailureReachesTheCaller() async {
        let spawns = ChildSpawnQueue(label: "com.cmuxterm.tests.child-spawn", qos: .utility)
        do throws(SpawnFailure) {
            _ = try await spawns.run { () throws(SpawnFailure) -> Int32 in throw SpawnFailure(code: ENOENT) }
            Issue.record("the spawn item's error was lost")
        } catch {
            #expect(error == SpawnFailure(code: ENOENT))
        }
    }

    /// The seam sets the clamp on the caller's attributes for utility and background, and leaves them alone
    /// above (the child then takes the spawn queue's QoS).
    @Test(arguments: ChildProcessQoS.allCases)
    func theSeamClampsOnlyUtilityAndBackgroundChildren(qos: ChildProcessQoS) throws {
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        let spawned = BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .record)) {
            spawnTrue(attributes: &attributes, qos: qos)
        }
        try #require(spawned.status == 0)
        reap(spawned.pid)
        var clamp = QOS_CLASS_UNSPECIFIED
        try #require(posix_spawnattr_get_qos_class_np(&attributes, &clamp) == 0)
        #expect(clamp == (qos.spawnClamp ?? QOS_CLASS_UNSPECIFIED))
    }

    /// Nil attributes spawn with the seam's own, which carry only the clamp.
    @Test func theSeamSpawnsWithItsOwnAttributesWhenGivenNone() throws {
        let spawned = BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .record)) {
            spawnTrue(attributes: nil, qos: .background)
        }
        try #require(spawned.status == 0)
        #expect(reap(spawned.pid) == 0)
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The acceptance of task 037: from main-actor code, a spawn through a spawn queue records no main-thread
    /// site, and the same spawn inline records one.
    @MainActor @Test func aSpawnThroughTheQueueRecordsNoMainViolation() async throws {
        let table = BlockingViolationTable(mode: .record)
        let spawns = ChildSpawnQueue(label: "com.cmuxterm.tests.child-spawn", qos: .userInitiated)
        let queued = await spawns.run { () -> SpawnedChild in
            // A dispatch block does not inherit task-locals: bind the test's table on the queue's thread.
            BlockingViolationTable.$scoped.withValue(table) { spawnTrue(attributes: nil, qos: spawns.qos) }
        }
        try #require(queued.status == 0)
        reap(queued.pid)
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)

        let inline = BlockingViolationTable.$scoped.withValue(table) { spawnTrue(attributes: nil, qos: .userInitiated) }
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

/// A spawn's status and, when it is 0, the child's pid.
private nonisolated struct SpawnedChild: Sendable {
    let status: Int32
    let pid: pid_t
}

/// Starts `/usr/bin/true` through the QoS seam.
private nonisolated func spawnTrue(attributes: UnsafeMutablePointer<posix_spawnattr_t?>?, qos: ChildProcessQoS) -> SpawnedChild {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    defer { argv.forEach { free($0) } }
    let status = blockingPosixSpawn(&pid, "/usr/bin/true", nil, attributes, argv, environ, qos: qos)
    return SpawnedChild(status: status, pid: pid)
}

/// Reaps `pid` and returns its exit code.
@discardableResult
private nonisolated func reap(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    return (status >> 8) & 0xFF
}
