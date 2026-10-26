import Foundation
import Testing

@testable import CmuxIrxTransport

/// The lock-guarded shared state the transport reads from many threads at
/// once (journal, inbound-activity clock, current device list). Run under
/// TSan (`swift test --sanitize=thread --filter IrxSharedStateConcurrencyTests`)
/// to prove the checked `Sendable` conformances hold.
@Suite struct IrxSharedStateConcurrencyTests {
    @Test func journalCountsEveryConcurrentRecordAndBoundsTheRing() async {
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "concurrency")
        let writers = 8
        let perWriter = 200

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    for index in 0..<perWriter {
                        journal.record("concurrency", "tick", ["writer": "\(writer)", "index": "\(index)"])
                        _ = journal.tail(4)
                    }
                }
            }
        }

        #expect(journal.counterSnapshot()["tick"] == writers * perWriter)
        #expect(journal.tail(Int.max).count == IrxJournal.ringCapacity)
    }

    @Test func activityClockKeepsTheLatestInstantUnderConcurrentRecords() async {
        let clock = IrxInboundActivityClock()
        let base = ContinuousClock.now
        let latest = base + .seconds(1_000)

        await withTaskGroup(of: Void.self) { group in
            for offset in 0...1_000 {
                group.addTask {
                    clock.record(at: base + .seconds(offset))
                    _ = clock.lastActivity
                }
            }
        }

        #expect(clock.lastActivity == latest)
        clock.record(at: base)
        #expect(clock.lastActivity == latest)
    }

    @Test func deviceListRestampsOnlyTheSnapshotItHolds() async {
        let current = IrxDeviceListCurrent()
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = IrxDeviceListSnapshot(
            entries: [:],
            rev: 7,
            issuedAt: issuedAt,
            ttlSeconds: 60,
            receivedAtWall: issuedAt,
            receivedAtMonotonic: .now
        )
        #expect(current.restamp(rev: 7, issuedAt: issuedAt + 1, receivedAtWall: issuedAt, receivedAtMonotonic: .now) == nil)
        current.replace(snapshot)

        await withTaskGroup(of: Void.self) { group in
            for step in 1...100 {
                group.addTask {
                    current.restamp(
                        rev: 7,
                        issuedAt: issuedAt + TimeInterval(step),
                        receivedAtWall: issuedAt,
                        receivedAtMonotonic: .now
                    )
                    _ = current.current
                }
            }
        }

        let held = current.current
        #expect(held?.rev == 7)
        #expect(held.map { $0.issuedAt > issuedAt } == true)
        current.clear()
        #expect(current.current == nil)
    }
}
