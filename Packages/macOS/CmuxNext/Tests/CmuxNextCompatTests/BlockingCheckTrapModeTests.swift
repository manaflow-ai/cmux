#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The mode a launch asks for, the same in Debug, bench and Nightly (`-c release -DCMUX_BLOCKING_CHECKS`, no
/// DEBUG): record by default, and `CMUX_BLOCKING_TRAP=1` as the opt-in crash mode, which hands the site to the
/// sink before it stops. Chrome's configurable DCHECK (base/check.h `DCHECK_IS_CONFIGURABLE`). Each test binds
/// its own table; trap cases run in a child process (exit tests).
@Suite(.serialized)
struct BlockingCheckTrapModeTests {
    @Test func withoutTheVariableACheckedBuildRecords() {
        #expect(BlockingViolationTable(environment: [:]).mode == .record)
        #expect(BlockingMode(environment: ["CMUX_BLOCKING_TRAP": "0"]) == .record)
        #expect(BlockingMode(environment: ["CMUX_BLOCKING_TRAP": "true"]) == .record)
    }

    @Test func theTrapVariableResolvesToTrap() {
        #expect(BlockingMode(environment: ["CMUX_BLOCKING_TRAP": "1"]) == .trap)
        #expect(BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP": "1"]).mode == .trap)
    }

    /// The opt-in crash mode stops the process in every checked build, a Nightly included.
    @Test func theTrapEnvironmentVariableTurnsTrapModeOn() async {
        await #expect(processExitsWith: .failure) {
            let table = BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP": "1"])
            await BlockingViolationTable.$scoped.withValue(table) {
                await MainActor.run { _ = FileManager.checked.fileExists(atPath: "/") }
            }
        }
    }

    /// A trap hands its site to the sink before the process stops: this sink ends the child with its own exit
    /// code, which it can only do while the main thread waits in the trap's flush.
    @Test func aTrapHandsItsSiteToTheSinkBeforeItStops() async {
        await #expect(processExitsWith: .exitCode(ExitingSink.exitCode)) {
            let table = BlockingViolationTable(mode: .trap, trapFlushMilliseconds: 10_000)  // a slow host still reaches the sink
            BlockingDetector(table: table).install(sink: ExitingSink())
            await BlockingViolationTable.$scoped.withValue(table) {
                await MainActor.run { _ = FileManager.checked.fileExists(atPath: "/") }
            }
        }
    }

    /// The flush takes every pending site to the sink before it returns, without the drain's own wake.
    @MainActor @Test func theTrapFlushDeliversPendingSitesSynchronously() {
        let table = BlockingViolationTable(mode: .record, startsDrain: false)
        let recorder = KindRecorder()
        BlockingDetector(table: table).install(sink: recorder)
        BlockingViolationTable.$scoped.withValue(table) { _ = FileManager.checked.fileExists(atPath: "/") }
        #expect(recorder.kinds.isEmpty)  // the wake source is held: only the flush can deliver it

        #expect(table.flushBeforeTrap() == .success)
        #expect(recorder.kinds == [.fileIO])
        table.startDrain()
    }

    /// A sink that does not return (it waits on a lock the trapping thread holds) delays the trap by the
    /// flush limit, never forever.
    @MainActor @Test func aStuckSinkDelaysTheTrapOnlyByTheFlushLimit() async {
        let table = BlockingViolationTable(mode: .record, trapFlushMilliseconds: 20, startsDrain: false)
        let sink = StuckSink()
        BlockingDetector(table: table).install(sink: sink)
        BlockingViolationTable.$scoped.withValue(table) { _ = FileManager.checked.fileExists(atPath: "/") }

        #expect(table.flushBeforeTrap() == .timedOut)
        sink.release.signal()
        table.startDrain()
        await table.flush()
        #expect(sink.recorded == 1)
    }

    /// An allowed call in trap mode neither traps nor reaches the sink.
    @MainActor @Test func anAllowedCallInTrapModeIsNotRecorded() async {
        let table = BlockingViolationTable(mode: .trap)
        let recorder = KindRecorder()
        BlockingDetector(table: table).install(sink: recorder)
        BlockingViolationTable.$scoped.withValue(table) {
            allowBlocking(BlockingAllowance(reviewed: "test")) { _ = FileManager.checked.fileExists(atPath: "/") }
        }
        await table.flush()
        #expect(recorder.kinds.isEmpty)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }
}

/// Collects the kinds the detector hands its sink.
private nonisolated final class KindRecorder: BlockingViolationSink {
    private let seen = Mutex<[BlockingKind]>([])

    var kinds: [BlockingKind] { seen.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        seen.withLock { $0.append(violation.kind) }
    }
}

/// A sink that ends the process with ``exitCode`` from the drain queue.
private nonisolated final class ExitingSink: BlockingViolationSink {
    static let exitCode: Int32 = 9

    func record(_ violation: BlockingViolation) {
        exit(Self.exitCode)
    }
}

/// A sink that does not return until ``release`` is signaled.
private nonisolated final class StuckSink: BlockingViolationSink {
    let release = DispatchSemaphore(value: 0)
    private let count = Mutex(0)

    var recorded: Int { count.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        release.wait()
        count.withLock { $0 += 1 }
    }
}
#endif
