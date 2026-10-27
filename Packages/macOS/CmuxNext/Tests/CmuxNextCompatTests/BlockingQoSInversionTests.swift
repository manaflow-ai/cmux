@testable import CmuxNextCompat
import Dispatch
import Testing

/// QoS inversions (plans/cmux-next/chrome-parity/p12-perf-process.md, task 230): `blockingSync` from a thread whose
/// QoS is above the target queue's records one inversion at its call site (Xcode's Thread Performance Checker case,
/// Chrome's rule that work a higher-priority sequence waits for is not posted below it, base/task/task_traits.h).
/// Each case waits from a user-interactive serial queue, the top class, so the waiter's class does not depend on
/// the test runner's thread, and binds its own table there (a dispatch block does not inherit task-locals).
@Suite(.serialized)
struct BlockingQoSInversionTests {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    @Test func aUserInteractiveSyncOntoAUtilityQueueIsOneInversion() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let utility = DispatchQueue(label: "com.cmuxterm.tests.qos-utility", qos: .utility)
        let line = await fromUserInteractive(table) { syncOnto(utility) }
        await table.flush()

        let detector = BlockingDetector(table: table)
        #expect(detector.qosInversions == [BlockingQoSInversion(
            location: "CmuxNextCompatTests/BlockingQoSInversionTests.swift:\(line)",
            waiter: .userInteractive, target: .utility, count: 1)])
        #expect(detector.qosInversionOverflow == 0)
    }

    /// A repeat at the same site counts on that site; reset zeroes it and keeps the site.
    @Test func repeatsCountOnOneSiteAndResetZeroesThem() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let utility = DispatchQueue(label: "com.cmuxterm.tests.qos-utility", qos: .utility)
        await fromUserInteractive(table) {
            var line: UInt = 0
            for _ in 0..<3 { line = syncOnto(utility) }
            return line
        }
        await table.flush()
        let detector = BlockingDetector(table: table)
        #expect(detector.qosInversions.map(\.count) == [3])

        detector.resetCounts()
        #expect(detector.qosInversions.map(\.count) == [0])
    }

    /// A queue at or above the waiter's class, and a queue made with no class (it runs at its submitters' class),
    /// are never an inversion.
    @Test(arguments: [true, false])
    func aWaitOntoAQueueNotBelowTheWaiterIsNoInversion(withoutClass: Bool) async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let target = DispatchQueue(label: "com.cmuxterm.tests.qos-target",
                                   qos: withoutClass ? .unspecified : .userInteractive)
        await fromUserInteractive(table) { syncOnto(target) }
        await table.flush()
        #expect(BlockingDetector(table: table).qosInversions.isEmpty)
    }

    @Test func classesCompareByTheKernelTierOrder() {
        #expect(ThreadQoS.userInteractive.isInverted(waitingOn: .utility))
        #expect(ThreadQoS.userInitiated.isInverted(waitingOn: .background))
        #expect(ThreadQoS.utility.isInverted(waitingOn: .maintenance))
        #expect(!ThreadQoS.utility.isInverted(waitingOn: .userInteractive))
        #expect(!ThreadQoS.utility.isInverted(waitingOn: .utility))
        #expect(!ThreadQoS.userInteractive.isInverted(waitingOn: .unspecified))
    }
    #else
    // MARK: Release: compiled out

    @Test func releaseBuildsCountNoInversion() async {
        let utility = DispatchQueue(label: "com.cmuxterm.tests.qos-utility", qos: .utility)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "com.cmuxterm.tests.qos-waiter", qos: .userInteractive).async {
                utility.blockingSync {}
                done.resume()
            }
        }
        #expect(BlockingDetector.forProcess().qosInversions.isEmpty)
        #expect(BlockingDetector.forProcess().qosInversionOverflow == 0)
    }
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// Runs `body` on a named user-interactive serial queue with `table` bound there; returns what `body` returns.
@discardableResult
private nonisolated func fromUserInteractive(
    _ table: BlockingViolationTable, _ body: @escaping @Sendable () -> UInt
) async -> UInt {
    await withCheckedContinuation { (done: CheckedContinuation<UInt, Never>) in
        DispatchQueue(label: "com.cmuxterm.tests.qos-waiter", qos: .userInteractive).async {
            done.resume(returning: BlockingViolationTable.$scoped.withValue(table) { body() })
        }
    }
}

/// One checked `blockingSync` onto `queue`; returns the line of the call.
private nonisolated func syncOnto(_ queue: DispatchQueue) -> UInt {
    let line: UInt = #line + 1
    queue.blockingSync {}
    return line
}
#endif
