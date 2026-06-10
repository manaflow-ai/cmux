import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct DiagnosticLogTests {
    /// Await the log's drain task until its ring reports `expected` events, so a
    /// test can assert on a deterministic post-drain state without sleeping. The
    /// drain task runs on the cooperative pool; `Task.yield()` lets it advance.
    /// Bounded so a regression that never drains fails instead of hanging.
    /// Await the drain task processing at least `expected` total events, so a
    /// test can assert on a deterministic post-drain state without sleeping.
    /// ``DiagnosticLog/processedCount()`` only grows (eviction does not lower
    /// it), so it is a stable barrier even when the ring is at capacity. The
    /// drain task runs on the cooperative pool; `Task.yield()` lets it advance.
    /// Bounded so a regression that never drains fails instead of hanging.
    private func waitForProcessed(_ log: DiagnosticLog, _ expected: Int) async {
        for _ in 0..<1_000_000 {
            if await log.processedCount() >= expected { return }
            await Task.yield()
        }
    }

    /// Record one event and await it draining into the ring, so the next record
    /// never overflows the stream buffer. Draining each event before recording
    /// the next means what survives is governed only by the ring's eviction
    /// (deterministic) and never by `.bufferingNewest`'s pending-drop policy
    /// (timing-dependent).
    private func recordAndDrain(
        _ log: DiagnosticLog,
        _ event: DiagnosticEvent,
        processedAfter: Int
    ) async {
        log.record(event)
        await waitForProcessed(log, processedAfter)
    }

    @Test func recordThenExportRoundTrips() async {
        let log = DiagnosticLog(
            capacity: 16,
            buildStamp: "cmux DEV test",
            anchorWallNanos: 1_700_000_000_000_000_000,
            anchorMonotonicNanos: 500
        )
        log.record(DiagnosticEvent(code: .connect, tNanos: 1_000))
        log.record(DiagnosticEvent(code: .pairOk, tNanos: 2_000, ms: 250))
        log.record(DiagnosticEvent(code: .inputSeqBehind, tNanos: 3_000, surface: 7, a: 10, b: 20))
        await waitForProcessed(log, 3)

        let blob = await log.export()
        let text = String(decoding: blob, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Header: version, anchors, count, build stamp.
        #expect(lines[0].hasPrefix("cmuxdiag v1"))
        #expect(lines[0].contains("anchorWallNs=1700000000000000000"))
        #expect(lines[0].contains("anchorMonoNs=500"))
        #expect(lines[0].contains("count=3"))
        #expect(lines[0].contains("build=cmux DEV test"))

        // One compact row per event: tNanos,code,surface,ms,a,b,c (absent = empty).
        #expect(lines[1] == "1000,1,,,,,")
        #expect(lines[2] == "2000,2,,250,,,")
        #expect(lines[3] == "3000,7,7,,10,20,")
    }

    @Test func ringEvictionDropsOldest() async {
        let log = DiagnosticLog(capacity: 3)
        // Drain each event before recording the next so eviction is governed
        // purely by the ring (not by the stream's bufferingNewest drop policy).
        for i in 0..<6 {
            await recordAndDrain(
                log,
                DiagnosticEvent(code: .connect, tNanos: UInt64(i)),
                processedAfter: i + 1
            )
        }
        #expect(await log.count() == 3)

        let text = String(decoding: await log.export(), as: UTF8.self)
        let rows = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .filter { !$0.isEmpty }
            .map(String.init)
        #expect(rows.count == 3)
        // Oldest (tNanos 0,1,2) evicted; newest (3,4,5) retained, in order.
        #expect(rows[0].hasPrefix("3,"))
        #expect(rows[1].hasPrefix("4,"))
        #expect(rows[2].hasPrefix("5,"))
    }

    @Test func recordIsNonBlockingUnderBurst() async {
        // A burst far larger than capacity must not block the recorder: every
        // `record` returns synchronously (no await), and the ring stays bounded
        // by capacity once the drain settles. `.bufferingNewest` drops the
        // oldest *pending* events, so the final ring is bounded, not exact.
        let capacity = 64
        let log = DiagnosticLog(capacity: capacity)
        let burst = 50_000
        for i in 0..<burst {
            log.record(DiagnosticEvent(code: .renderGridLag, tNanos: UInt64(i), ms: 1))
        }
        // The recorder never suspended; we reach here immediately. Let the drain
        // settle and confirm the ring never exceeds capacity.
        await waitForProcessed(log, 1)
        let count = await log.count()
        #expect(count >= 1)
        #expect(count <= capacity)
    }

    @Test func circularBufferWrapsAndPreservesChronologicalOrder() async {
        // Drive the O(1) ring past several full wrap cycles and confirm export
        // still yields exactly the newest `capacity` events in record order,
        // proving the head/offset arithmetic is correct across the wrap boundary.
        let capacity = 4
        let log = DiagnosticLog(capacity: capacity)
        let total = 13 // 3 full cycles + 1, so head wraps and lands mid-array
        for i in 0..<total {
            await recordAndDrain(
                log,
                DiagnosticEvent(code: .connect, tNanos: UInt64(i)),
                processedAfter: i + 1
            )
        }
        #expect(await log.count() == capacity)

        let text = String(decoding: await log.export(), as: UTF8.self)
        let rows = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .filter { !$0.isEmpty }
            .map(String.init)
        #expect(rows.count == capacity)
        // Newest `capacity` events are tNanos 9,10,11,12, in order.
        #expect(rows[0].hasPrefix("9,"))
        #expect(rows[1].hasPrefix("10,"))
        #expect(rows[2].hasPrefix("11,"))
        #expect(rows[3].hasPrefix("12,"))
    }

    @Test func exportOnEmptyLogHasHeaderOnly() async {
        let log = DiagnosticLog(capacity: 8)
        let text = String(decoding: await log.export(), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("cmuxdiag v1"))
        #expect(lines[0].contains("count=0"))
        // No build stamp segment when empty default was used.
        #expect(!lines[0].contains("build="))
        // Nothing after the header but the trailing newline split.
        #expect(lines.filter { !$0.isEmpty }.count == 1)
    }
}
