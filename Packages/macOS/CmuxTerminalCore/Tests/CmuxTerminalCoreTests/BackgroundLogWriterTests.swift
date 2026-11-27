import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite
struct BackgroundLogWriterTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bg-writer-test-\(UUID().uuidString).log")
    }

    @Test func writesEnqueuedLinesInOrderWithMonotonicSequence() async {
        let sink = RecordingSink()
        let writer = BackgroundLogWriter(startUptime: 0, sink: sink)
        for index in 0..<50 {
            writer.log("message-\(index)", isMainThread: true)
        }

        let lines = await sink.waitForLines(50)
        #expect(lines.count == 50)
        for (index, line) in lines.enumerated() {
            // The FIFO stream + single consumer preserve submission order, and the
            // seq counter increments once per consumed line.
            #expect(line.contains("seq=\(index + 1) "))
            #expect(line.contains("cmux bg: message-\(index)"))
            #expect(line.contains("thread=main"))
        }
    }

    @Test func formatsLineDeterministicallyFromInjectedClock() async {
        let sink = RecordingSink()
        // startUptime 1.0, sampled uptime 2.5 → t+1500.000ms; mediaTime 3.0 →
        // frame60=180, frame120=360.
        let writer = BackgroundLogWriter(
            startUptime: 1.0,
            sink: sink,
            now: { (Date(timeIntervalSince1970: 0), 2.5, 3.0) }
        )
        writer.log("hello", isMainThread: true)

        let line = await sink.waitForLines(1)[0]
        #expect(line.contains("seq=1 "))
        #expect(line.contains("t+1500.000ms"))
        #expect(line.contains("thread=main"))
        #expect(line.contains("frame60=180 "))
        #expect(line.contains("frame120=360 "))
        #expect(line.hasSuffix("cmux bg: hello\n"))
    }

    @Test func capturesCallerThreadLabel() async {
        let sink = RecordingSink()
        let writer = BackgroundLogWriter(startUptime: 0, sink: sink)
        // Emit from a non-main thread; the label must reflect the caller, not the
        // consumer task (which is itself off the main thread).
        let queue = DispatchQueue(label: "test.background.emit")
        queue.sync {
            writer.log("from-background", isMainThread: Thread.isMainThread)
        }

        let lines = await sink.waitForLines(1)
        #expect(lines.contains { $0.contains("thread=background") && $0.contains("cmux bg: from-background") })
    }

    @Test func concurrentEmittersProduceUniqueMonotonicSequence() async {
        let sink = RecordingSink()
        let writer = BackgroundLogWriter(startUptime: 0, sink: sink)
        let total = 200
        DispatchQueue.concurrentPerform(iterations: total) { index in
            writer.log("concurrent-\(index)", isMainThread: false)
        }

        let lines = await sink.waitForLines(total)
        #expect(lines.count == total)

        // Every line carries a distinct seq in 1...total, regardless of how many
        // threads raced to emit — the single consumer serializes the counter and
        // forwards lines without any explicit lock.
        var sequences: Set<Int> = []
        for line in lines {
            guard let range = line.range(of: "seq="),
                  let end = line[range.upperBound...].firstIndex(of: " "),
                  let value = Int(line[range.upperBound..<end])
            else {
                Issue.record("line missing seq= field: \(line)")
                continue
            }
            sequences.insert(value)
        }
        #expect(sequences == Set(1...total))
    }

    @Test func boundedBufferDropsOldestUnderFlood() async {
        // Gate the consumer so a burst far larger than the buffer overflows it; the
        // bounded `.bufferingNewest` policy must drop the oldest entries.
        let sink = RecordingSink(gated: true)
        let writer = BackgroundLogWriter(startUptime: 0, sink: sink, maxBufferedEntries: 8)
        let burst = 2000
        for index in 0..<burst {
            writer.log("flood-\(index)", isMainThread: false)
        }
        // The newest entry survives drop-oldest, so it doubles as a drain marker.
        writer.log("SENTINEL", isMainThread: false)
        await sink.openGate()

        let lines = await sink.waitForLineContaining("SENTINEL")
        // Only the buffer capacity (+ at most the in-flight entry) survive the
        // 2001-entry burst: the bound holds, far below `burst`.
        #expect(lines.count <= 8 + 2)
        #expect(lines.count >= 1)
        #expect(lines.last?.contains("cmux bg: SENTINEL") == true)
        // Delivered seq stays contiguous from 1: dropped entries never reach the
        // consumer, so they leave no gap.
        for (index, line) in lines.enumerated() {
            #expect(line.contains("seq=\(index + 1) "))
        }
    }

    @Test func fileSinkAppendsThroughOneLongLivedHandle() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // The actor's `write` is awaitable, so the appends are deterministic with no
        // polling. A second write after the file exists must append, not truncate —
        // proving the sink reuses one handle.
        let sink = FileBackgroundLogLineSink(fileURL: url)
        await sink.write("line-1\n")
        await sink.write("line-2\n")

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "line-1\nline-2\n")
    }
}
