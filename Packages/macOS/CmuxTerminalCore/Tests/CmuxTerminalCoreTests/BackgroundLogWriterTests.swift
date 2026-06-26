import Foundation
import Testing
import CmuxTerminalCore

@Suite
struct BackgroundLogWriterTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bg-writer-test-\(UUID().uuidString).log")
    }

    @Test func writesEnqueuedLinesInOrderWithMonotonicSequence() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        for index in 0..<50 {
            writer.log("message-\(index)", isMainThread: true)
        }
        writer.drain()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 50)
        for (index, line) in lines.enumerated() {
            // The serial drain queue preserves submission order, and the seq
            // counter increments once per drained line.
            #expect(line.contains("seq=\(index + 1) "))
            #expect(line.contains("cmux bg: message-\(index)"))
            #expect(line.contains("thread=main"))
        }
    }

    @Test func appendsAcrossBatchesWithSingleLongLivedHandle() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        writer.log("first", isMainThread: false)
        writer.drain()
        // A second emission after the file already exists must append rather than
        // truncate — proving the writer reuses one handle instead of reopening.
        writer.log("second", isMainThread: true)
        writer.drain()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].contains("cmux bg: first"))
        #expect(lines[0].contains("thread=background"))
        #expect(lines[0].contains("seq=1 "))
        #expect(lines[1].contains("cmux bg: second"))
        #expect(lines[1].contains("thread=main"))
        #expect(lines[1].contains("seq=2 "))
    }

    @Test func capturesCallerThreadLabel() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        // Emit from a non-main thread; the label must reflect the caller, not the
        // serial drain queue (which is itself a background queue).
        let queue = DispatchQueue(label: "test.background.emit")
        queue.sync {
            writer.log("from-background", isMainThread: Thread.isMainThread)
        }
        writer.drain()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("thread=background"))
        #expect(contents.contains("cmux bg: from-background"))
    }

    @Test func concurrentEmittersProduceUniqueMonotonicSequence() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = BackgroundLogWriter(fileURL: url, startUptime: 0)
        let total = 200
        DispatchQueue.concurrentPerform(iterations: total) { index in
            writer.log("concurrent-\(index)", isMainThread: false)
        }
        writer.drain()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == total)

        // Every line carries a distinct seq in 1...total, regardless of how many
        // threads raced to emit — the serial queue serializes the counter and the
        // appends without an explicit lock.
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
}
