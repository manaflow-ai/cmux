import CmuxNextControl
import CmuxNextInput
@testable import CmuxNextInputDiagnostics
import CmuxNextInputCore
import Foundation
import Testing

/// The app's `debug.input` latency section (``InputLatencyDebugSource``, the dogfood ask of 2026-10-27: "debug.input
/// shows latency absent, so the app has no per-key data"). Keys the tracker closed are in the read at once, not only
/// after half a ring (128 slots) fills; the batch carries the tracker's lost slots; reset starts the section over.
@MainActor @Suite(.serialized)
struct InputLatencyDebugSourceTests {
    /// Closes `count` view keys through the harness's fake commit boundary, 1 ms apart.
    private func closeKeys(_ count: Int, in harness: InputLatencyTrackerTests.Harness) throws {
        for _ in 0..<count {
            let now = harness.now
            _ = try #require(harness.tracker.begin(kind: .keyPress, target: .textView, entrypoint: .person,
                                                   eventTimestamp: TimeInterval(now - 2_000_000) / 1e9, window: nil))
            harness.advance(1_000_000)
            harness.commit()
        }
    }

    @Test func keysTheTrackerClosedAreInTheReadBeforeAHalfRingFills() async throws {
        let harness = InputLatencyTrackerTests.Harness()
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        let source = InputLatencyDebugSource(reporter: reporter, tracker: harness.tracker, mainWork: DebugInputTests.mainWork())
        source.follow { 8_333_333 }
        let debugInput = DebugInput(sources: [source])

        try closeKeys(3, in: harness)
        #expect(harness.emitted.count == 3, "the tracker closed every key")

        let reply = try await debugInput.reply(to: .read([.latency]))
        #expect(reply["absent"] == .array([]))
        let latency = try DebugInputTests.decode(InputLatencySnapshot.self, reply["latency"])
        #expect(latency.slotsReceived == 3, "3 closed keys, far fewer than a half ring, are in the read")
        #expect(latency.rows.filter { $0.kind == "keyPress" && $0.target == "textView" }.map(\.count) == [3])
        #expect(latency.rows.first?.total.count == 3, "each key has its total, generated to presented")

        try closeKeys(2, in: harness)
        let later = try DebugInputTests.decode(InputLatencySnapshot.self, try await debugInput.reply(to: .read([.latency]))["latency"])
        #expect(later.slotsReceived == 5, "a second read adds only the keys closed since the first")

        _ = try await debugInput.reply(to: .reset)
        let reset = try DebugInputTests.decode(InputLatencySnapshot.self, try await debugInput.reply(to: .read([.latency]))["latency"])
        #expect(reset.slotsReceived == 0 && reset.rows.isEmpty)
        reporter.finish()
        await reader.value
    }

    @Test func theBatchCarriesTheSlotsTheRingLostBeforeTheRead() async throws {
        // A 4-slot ring with no sink yet: 6 closed keys overwrite the 2 oldest before anything takes them.
        let harness = InputLatencyTrackerTests.Harness(ringCapacity: 4)
        try closeKeys(6, in: harness)
        let reporter = InputLatencyReporter()
        let reader = Task.detached(priority: .utility) { await reporter.run() }
        let source = InputLatencyDebugSource(reporter: reporter, tracker: harness.tracker, mainWork: DebugInputTests.mainWork())
        source.follow { 8_333_333 }

        let latency = try DebugInputTests.decode(InputLatencySnapshot.self,
                                                 try await DebugInput(sources: [source]).reply(to: .read([.latency]))["latency"])
        #expect(latency.slotsReceived == 4)
        #expect(latency.slotsDropped == 2)
        #expect(harness.tracker.droppedTotal == 2)
        reporter.finish()
        await reader.value
    }

    @Test func theSlotsActionListsEachKeyNewestFirstAndResetStartsItOver() async throws {
        let harness = InputLatencyTrackerTests.Harness()
        let debugInput = DebugInput(sources: [], recorders: [InputLatencySlotsRecorder(tracker: harness.tracker,
                                                                                       mainWork: DebugInputTests.mainWork())])
        let firstEvent = harness.now - 2_000_000
        try closeKeys(3, in: harness)

        let reply = try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("slots")]))
        let object = try DebugInputTests.object(reply)
        #expect(object["closed"] as? Int == 3)
        let slots = try #require(object["slots"] as? [[String: Any]])
        #expect(slots.count == 3)
        #expect(slots.allSatisfy { $0["kind"] as? String == "keyPress" && $0["target"] as? String == "textView" })
        let generated = slots.compactMap { ($0["generated_ns"] as? NSNumber)?.uint64Value }
        #expect(generated == generated.sorted(by: >), "newest first")
        #expect(generated.last.map { max($0, firstEvent) - min($0, firstEvent) < 1_000 } == true, "the oldest is the first key's event")
        // FakePresentation answers commit + 1 ms; each key's event is 2 ms old at its begin and commits 1 ms later.
        #expect(slots.allSatisfy { ($0["total_ms"] as? Double).map { abs($0 - 4) < 0.001 } == true })
        #expect(slots.allSatisfy { ($0["stages_ms"] as? [String: Double])?["presented"] != nil })

        _ = try await debugInput.reply(to: .reset)
        try closeKeys(1, in: harness)
        let after = try DebugInputTests.object(try await debugInput.reply(to: DebugInput.Request(params: ["action": .string("slots")])))
        #expect((after["slots"] as? [[String: Any]])?.count == 1, "only the key closed since the reset")
        let all = try DebugInputTests.object(try await debugInput.reply(
            to: DebugInput.Request(params: ["action": .string("slots"), "since_launch": .bool(true)])))
        #expect((all["slots"] as? [[String: Any]])?.count == 4)
    }
}
