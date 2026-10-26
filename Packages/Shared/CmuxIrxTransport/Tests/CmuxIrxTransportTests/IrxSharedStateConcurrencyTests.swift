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

    /// The file write happens outside the journal's lock; `O_APPEND` keeps
    /// every concurrent line whole.
    @Test func journalFileKeepsEveryConcurrentLineWhole() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-journal-concurrency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.jsonl")
        let writers = 8
        let perWriter = 200
        do {
            let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "concurrency", journalFileURL: file)
            await withTaskGroup(of: Void.self) { group in
                for writer in 0..<writers {
                    group.addTask {
                        for index in 0..<perWriter {
                            journal.record("concurrency", "line", ["writer": "\(writer)", "index": "\(index)"])
                        }
                    }
                }
            }
        }
        let reopened = IrxJournal(subsystem: "dev.cmux.tests", category: "concurrency", journalFileURL: file)
        reopened.record("concurrency", "reopened")

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == writers * perWriter + 1)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["component"] as? String == "concurrency")
        }
        #expect(lines.last.map { $0.contains("\"event\":\"reopened\"") } == true)
    }

    @Test func controlPlaneDatesDecodeWithOrWithoutFractionsAndOffsets() throws {
        struct Stamp: Decodable { let at: Date }
        let decoder = IrxControlPlaneClient.makeDecoder()
        let cases: [(String, TimeInterval)] = [
            ("2026-08-27T02:49:40Z", 1_787_798_980),
            ("2026-08-27T02:49:40.123Z", 1_787_798_980.123),
            ("2026-08-27T02:49:40+02:00", 1_787_791_780),
            ("2026-08-27T02:49:40.5-05:30", 1_787_818_780.5),
        ]
        for (raw, expected) in cases {
            let stamp = try decoder.decode(Stamp.self, from: Data("{\"at\":\"\(raw)\"}".utf8))
            #expect(abs(stamp.at.timeIntervalSince1970 - expected) < 0.001, "\(raw)")
        }
        for raw in ["2026-08-27T02:49:40", "2026-08-27", "garbage"] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(Stamp.self, from: Data("{\"at\":\"\(raw)\"}".utf8))
            }
        }
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
