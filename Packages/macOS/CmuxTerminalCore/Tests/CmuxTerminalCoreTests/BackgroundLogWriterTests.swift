import Foundation
import Testing
import CmuxTerminalCore

@Suite
struct BackgroundLogWriterTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bg-writer-test-\(UUID().uuidString).log")
    }

    /// Polls `url` until it holds at least `count` complete (newline-terminated)
    /// lines, then returns them. The writer drains on a background task, so tests
    /// wait for the flush rather than a synchronous barrier.
    private func waitForLines(
        _ url: URL,
        count: Int,
        timeout: Duration = .seconds(10)
    ) async throws -> [String] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               contents.hasSuffix("\n") {
                let lines = contents
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                if lines.count >= count {
                    return lines
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Polls `url` until it has stopped growing for `settle`, then returns its
    /// lines. Used by the flood test, where drop-oldest means the final line count
    /// is not known in advance.
    private func waitForFloodToSettle(
        _ url: URL,
        settle: Duration = .milliseconds(400),
        timeout: Duration = .seconds(15)
    ) async throws -> [String] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastContent = ""
        var lastChange = ContinuousClock.now
        while ContinuousClock.now < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents != lastContent {
                lastContent = contents
                lastChange = ContinuousClock.now
            } else if !contents.isEmpty,
                      contents.hasSuffix("\n"),
                      (ContinuousClock.now - lastChange) >= settle {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return lastContent
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    @Test func writesEnqueuedLinesInOrderWithMonotonicSequence() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        for index in 0..<50 {
            writer.log("message-\(index)", isMainThread: true)
        }

        let lines = try await waitForLines(url, count: 50)
        #expect(lines.count == 50)
        for (index, line) in lines.enumerated() {
            // The FIFO stream + single consumer preserve submission order, and the
            // seq counter increments once per consumed line.
            #expect(line.contains("seq=\(index + 1) "))
            #expect(line.contains("cmux bg: message-\(index)"))
            #expect(line.contains("thread=main"))
        }
    }

    @Test func appendsAcrossBatchesWithSingleLongLivedHandle() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        writer.log("first", isMainThread: false)
        _ = try await waitForLines(url, count: 1)
        // A second emission after the file already exists must append rather than
        // truncate — proving the consumer reuses one handle instead of reopening.
        writer.log("second", isMainThread: true)

        let lines = try await waitForLines(url, count: 2)
        #expect(lines.count == 2)
        #expect(lines[0].contains("cmux bg: first"))
        #expect(lines[0].contains("thread=background"))
        #expect(lines[0].contains("seq=1 "))
        #expect(lines[1].contains("cmux bg: second"))
        #expect(lines[1].contains("thread=main"))
        #expect(lines[1].contains("seq=2 "))
    }

    @Test func capturesCallerThreadLabel() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        // Emit from a non-main thread; the label must reflect the caller, not the
        // consumer task (which is itself off the main thread).
        let queue = DispatchQueue(label: "test.background.emit")
        queue.sync {
            writer.log("from-background", isMainThread: Thread.isMainThread)
        }

        let lines = try await waitForLines(url, count: 1)
        #expect(lines.contains { $0.contains("thread=background") && $0.contains("cmux bg: from-background") })
    }

    @Test func concurrentEmittersProduceUniqueMonotonicSequence() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        let total = 200
        DispatchQueue.concurrentPerform(iterations: total) { index in
            writer.log("concurrent-\(index)", isMainThread: false)
        }

        let lines = try await waitForLines(url, count: total)
        #expect(lines.count == total)

        // Every line carries a distinct seq in 1...total, regardless of how many
        // threads raced to emit — the single consumer serializes the counter and
        // the appends without any explicit lock.
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

    @Test func boundedBufferDropsOldestUnderFloodWithoutCorruptingDelivery() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // A tiny buffer plus a large synchronous burst lets emission outpace the
        // single file writer, exercising the drop-oldest bound.
        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0, maxBufferedEntries: 8)
        let burst = 2000
        for index in 0..<burst {
            writer.log("flood-\(index)", isMainThread: false)
        }

        let lines = try await waitForFloodToSettle(url)
        // The writer survives the burst (no hang/crash) and delivers some lines.
        #expect(!lines.isEmpty)
        #expect(lines.count <= burst)
        // Every delivered line is well-formed, and seq stays contiguous from 1:
        // dropped entries never reach the consumer, so they leave no seq gap.
        for (index, line) in lines.enumerated() {
            #expect(line.contains("seq=\(index + 1) "))
            #expect(line.contains("cmux bg: flood-"))
        }
    }
}
