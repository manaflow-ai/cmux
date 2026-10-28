#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import Dispatch
import Foundation
import Testing

/// The sink sees every site of the launch once: a site recorded before the composition
/// root installs the sink is replayed to it at install, a site after reaches it by the drain, and
/// every call runs on the detector's drain queue.
@Suite(.serialized)
struct BlockingSinkReplayTests {
    @MainActor @Test func aSiteBeforeInstallIsReplayedOnce() async {
        let table = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush()  // drained with no sink: only published

        let sink = QueueRecordingSink()
        BlockingDetector(table: table).install(sink: sink)
        await table.flush()
        #expect(sink.kinds == [.fileIO])

        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()  // the same site again: counted only
            signaledSemaphore().blockingWait()  // a new site: by the drain
        }
        await table.flush()
        #expect(sink.kinds == [.fileIO, .syncWait])
    }

    @MainActor @Test func theSinkRunsOnTheDrainQueue() async {
        let table = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush()
        let sink = QueueRecordingSink()
        BlockingDetector(table: table).install(sink: sink)  // the replay
        await BlockingViolationTable.$scoped.withValue(table) {
            signaledSemaphore().blockingWait()  // the drain
        }
        await table.flush()

        #expect(sink.queues == ["com.cmuxterm.app.next.blocking-drain", "com.cmuxterm.app.next.blocking-drain"])
    }

    @MainActor @Test func aReplacedSinkGetsTheSitesTooAndNilStopsDelivery() async {
        let table = BlockingViolationTable(mode: .record)
        let first = QueueRecordingSink()
        BlockingDetector(table: table).install(sink: first)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush()

        let second = QueueRecordingSink()
        BlockingDetector(table: table).install(sink: second)
        BlockingDetector(table: table).install(sink: nil)
        await BlockingViolationTable.$scoped.withValue(table) {
            signaledSemaphore().blockingWait()
        }
        await table.flush()

        #expect(first.kinds == [.fileIO])
        #expect(second.kinds == [.fileIO])
    }
}

/// One file-io call site, whoever calls it (the detector checks the thread when it runs).
private nonisolated func readRoot() {
    _ = FileManager.checked.fileExists(atPath: "/")
}

private nonisolated func signaledSemaphore() -> DispatchSemaphore {
    DispatchSemaphore(value: 1)
}

/// Records each violation's kind and the label of the queue it ran on.
private nonisolated final class QueueRecordingSink: BlockingViolationSink {
    private let seen = Mutex<[(BlockingKind, String)]>([])

    var kinds: [BlockingKind] { seen.withLock { $0.map(\.0) } }
    var queues: [String] { seen.withLock { $0.map(\.1) } }

    func record(_ violation: BlockingViolation) {
        let label = String(cString: __dispatch_queue_get_label(nil))
        seen.withLock { $0.append((violation.kind, label)) }
    }
}
#endif
