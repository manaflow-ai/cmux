import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDebugLogSinkTests {
    @Test func appendRetainsOrderInSnapshot() async {
        let sink = MobileDebugLogSink()
        await sink.append("first")
        await sink.append("second")
        let snapshot = await sink.snapshot()
        let lines = snapshot.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("first"))
        #expect(lines[1].hasSuffix("second"))
    }

    @Test func snapshotWithCountMatchesAppends() async {
        let sink = MobileDebugLogSink()
        for i in 0..<5 {
            await sink.append("line \(i)")
        }
        let result = await sink.snapshotWithCount()
        #expect(result.count == 5)
        #expect(result.body.contains("line 4"))
    }

    @Test func capacityEvictsOldestLines() async {
        let sink = MobileDebugLogSink(capacity: 3)
        for i in 0..<6 {
            await sink.append("L\(i)")
        }
        let result = await sink.snapshotWithCount()
        #expect(result.count == 3)
        #expect(!result.body.contains("L0"))
        #expect(!result.body.contains("L2"))
        #expect(result.body.contains("L3"))
        #expect(result.body.contains("L5"))
    }

    @Test func clearEmptiesBuffer() async {
        let sink = MobileDebugLogSink()
        await sink.append("x")
        await sink.clear()
        let result = await sink.snapshotWithCount()
        #expect(result.count == 0)
        #expect(result.body.isEmpty)
    }

    @Test func timestampUsesInjectedClock() async {
        // A monotonic stepping clock: each read advances 1.5s from a fixed base.
        // The first read seeds `startedAt`; the second is the append time, so the
        // elapsed prefix is deterministically 1.500s.
        let clock = SteppingClock(base: Date(timeIntervalSince1970: 1_000), step: 1.5)
        let sink = MobileDebugLogSink(now: { clock.next() })
        await sink.append("hello")
        let snapshot = await sink.snapshot()
        #expect(snapshot.contains("1.500"))
        #expect(snapshot.hasSuffix("hello"))
    }

    /// A deterministic clock that advances a fixed step on every read.
    ///
    /// Mutation is serialized through an `NSLock` confined to this test fixture;
    /// it never escapes the suite and is read serially by the sink under test.
    private final class SteppingClock: @unchecked Sendable {
        private let base: Date
        private let step: TimeInterval
        private let lock = NSLock()
        private var tick = 0

        init(base: Date, step: TimeInterval) {
            self.base = base
            self.step = step
        }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            let value = base.addingTimeInterval(Double(tick) * step)
            tick += 1
            return value
        }
    }

    @Test func linesStreamYieldsAppendedLines() async {
        let sink = MobileDebugLogSink()
        let stream = await sink.lines()
        await sink.append("streamed")
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.hasSuffix("streamed") == true)
    }
}
