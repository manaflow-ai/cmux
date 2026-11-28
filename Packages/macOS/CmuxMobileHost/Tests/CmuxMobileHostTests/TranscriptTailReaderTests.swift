import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileHost

@Suite("Transcript tail reader", .timeLimit(.minutes(2)))
struct TranscriptTailReaderTests {
    private func makeFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-reader-\(UUID().uuidString).jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func decodedLines(_ reader: TranscriptTailReader, _ window: TranscriptTailWindow, maxRecordBytes: Int) -> [String] {
        Array(reader.lines(in: window.lineRanges, maxRecordBytes: maxRecordBytes))
    }

    @Test("the window holds the newest lines within the line limit, with absolute indexes")
    func lineLimit() throws {
        let url = try makeFile("a\nbb\nccc\ndddd\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 2, maxBytes: 100, maxRecordBytes: 100)
        let window = try reader.scan(limits: limits)
        #expect(window.completeLineCount == 4)
        #expect(window.firstLine == 2)
        #expect(window.byteCount == 14)
        #expect(decodedLines(reader, window, maxRecordBytes: 100) == ["ccc", "dddd"])
    }

    @Test("the window stops at the byte budget but a skipped record costs none of it")
    func byteBudget() throws {
        let url = try makeFile("aaaa\nbbbb\n\(String(repeating: "h", count: 50))\ncccc\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 100, maxBytes: 8, maxRecordBytes: 10)
        let window = try reader.scan(limits: limits)
        #expect(window.firstLine == 1)
        #expect(window.oversizedLines == [2])
        #expect(decodedLines(reader, window, maxRecordBytes: 10) == ["bbbb", "", "cccc"])
    }

    @Test("bytes after the last newline are a fragment, not a line")
    func trailingFragment() throws {
        let url = try makeFile("line\npartial")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 10, maxBytes: 100, maxRecordBytes: 100)
        let window = try reader.scan(limits: limits)
        #expect(window.completeLineCount == 1)
        #expect(window.byteCount == 12)
        #expect(String(decoding: reader.data(in: window.trailingFragment), as: UTF8.self) == "partial")
    }

    @Test("the trailing fragment is charged to the byte budget")
    func fragmentChargedToBudget() throws {
        let url = try makeFile("aaaa\nbbbb\npartial")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 10, maxBytes: 12, maxRecordBytes: 100)
        let window = try reader.scan(limits: limits)
        // 7 fragment bytes leave room for "bbbb" but not "aaaa".
        #expect(window.firstLine == 1)
        #expect(decodedLines(reader, window, maxRecordBytes: 100) == ["bbbb"])
    }

    @Test("an oversized trailing fragment costs no budget")
    func oversizedFragmentCostsNothing() throws {
        let url = try makeFile("aaaa\nbbbb\n\(String(repeating: "p", count: 50))")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 10, maxBytes: 8, maxRecordBytes: 10)
        let window = try reader.scan(limits: limits)
        #expect(window.firstLine == 0)
    }

    @Test("a zero line limit yields an empty window")
    func zeroLineLimit() throws {
        let url = try makeFile("a\nb\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 0, maxBytes: 100, maxRecordBytes: 100)
        let window = try reader.scan(limits: limits)
        #expect(window.completeLineCount == 2)
        #expect(window.firstLine == 2)
        #expect(window.lineRanges.isEmpty)
    }

    @Test("an empty file has an empty window")
    func emptyFile() throws {
        let url = try makeFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 10, maxBytes: 100, maxRecordBytes: 100)
        let window = try reader.scan(limits: limits)
        #expect(window.completeLineCount == 0)
        #expect(window.lineRanges.isEmpty)
        #expect(window.trailingFragment.isEmpty)
    }

    @Test("a multi-gigabyte file yields a window sized by the limits")
    func multiGigabyteFile() throws {
        // Sparse, so the test exercises real offsets without the disk cost.
        let url = try makeFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let holeBytes: UInt64 = 3 * 1024 * 1024 * 1024
        try handle.truncate(atOffset: holeBytes)
        try handle.seek(toOffset: holeBytes)
        try handle.write(contentsOf: Data("\nsecond\nthird\n".utf8))
        try handle.close()

        let reader = try #require(TranscriptTailReader(path: url.path))
        let limits = TranscriptTailLimits(maxLines: 4, maxBytes: 1024, maxRecordBytes: 1024)
        let window = try reader.scan(limits: limits)
        #expect(window.completeLineCount == 3)
        #expect(window.firstLine == 0)
        #expect(window.oversizedLines == [0])
        #expect(window.byteCount == holeBytes + 14)
        #expect(decodedLines(reader, window, maxRecordBytes: 1024) == ["", "second", "third"])
    }

    @Test("a cancelled task stops scanning")
    func cancelledScanThrows() async throws {
        let url = try makeFile("a\nb\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let limits = TranscriptTailLimits(maxLines: 10, maxBytes: 100, maxRecordBytes: 100)
        let path = url.path
        let task = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            let reader = TranscriptTailReader(path: path)
            do {
                _ = try reader?.scan(limits: limits)
                return false
            } catch {
                return error is CancellationError
            }
        }
        #expect(await task.value)
    }

    @Test("cancellation between records ends the line sequence")
    func cancelledLinesStop() async throws {
        let url = try makeFile("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let limits = TranscriptTailLimits(maxLines: 10, maxBytes: 100, maxRecordBytes: 100)
        let path = url.path
        let task = Task.detached { () -> [String] in
            guard let reader = TranscriptTailReader(path: path),
                  let window = try? reader.scan(limits: limits) else { return [] }
            var seen: [String] = []
            for line in reader.lines(in: window.lineRanges, maxRecordBytes: 100) {
                seen.append(line)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return seen
        }
        #expect(await task.value == ["a"])
    }

    @Test("stopping during the first read abandons it and start returns")
    func stopAbandonsInitialLoad() async throws {
        let url = try makeFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64 * 1024 * 1024 * 1024)
        try handle.close()

        let tailer = AgentChatTranscriptTailer(sessionID: "session", agentKind: .codex, path: url.path) { _ in }
        let started = Task { await tailer.start() }
        await tailer.stop()
        await started.value
        #expect(await tailer.didAbandonInitialLoad)
    }

    @Test("a completed first read is not abandoned by a later stop")
    func stopAfterLoadKeepsHistory() async throws {
        let url = try makeFile("{}\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = AgentChatTranscriptTailer(sessionID: "session", agentKind: .codex, path: url.path) { _ in }
        await tailer.start()
        await tailer.stop()
        #expect(await tailer.didAbandonInitialLoad == false)
    }

    @Test("a backlog larger than the batch size arrives in several batches with contiguous seqs")
    func longBacklogPublishesInBatches() async throws {
        let url = try makeFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        let (batches, continuation) = AsyncStream.makeStream(of: AgentChatTranscriptTailer.Batch.self)
        let tailer = AgentChatTranscriptTailer(
            sessionID: "session",
            agentKind: .codex,
            path: url.path,
            maxInitialBytes: 1024 * 1024,
            maxRecordBytes: 1024 * 1024
        ) { batch in
            continuation.yield(batch)
        }
        await tailer.start()

        let text = String(repeating: "z", count: 16 * 1024)
        let line = #"{"timestamp":"2026-06-11T21:38:05.381Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"#
        let lineCount = 256
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(String(repeating: line + "\n", count: lineCount).utf8))
        try handle.close()

        var seqs: [Int] = []
        var batchCount = 0
        for await batch in batches {
            seqs.append(contentsOf: batch.appended.map(\.seq))
            batchCount += 1
            if seqs.last == lineCount - 1 { break }
        }
        await tailer.stop()
        continuation.finish()
        #expect(seqs == Array(0..<lineCount))
        #expect(batchCount > 1)
    }

    @Test("an oversized record appended live keeps its seq and its row")
    func oversizedAppend() async throws {
        let url = try makeFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        let (batches, continuation) = AsyncStream.makeStream(of: AgentChatTranscriptTailer.Batch.self)
        let tailer = AgentChatTranscriptTailer(
            sessionID: "session",
            agentKind: .codex,
            path: url.path,
            maxInitialBytes: 1024,
            maxRecordBytes: 64
        ) { batch in
            continuation.yield(batch)
        }
        await tailer.start()

        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data((String(repeating: "h", count: 200) + "\n").utf8))
        try handle.close()

        var appended: [ChatMessage] = []
        for await batch in batches {
            appended = batch.appended
            break
        }
        await tailer.stop()
        continuation.finish()
        #expect(appended.map(\.seq) == [0])
        if case .unsupported(let payload) = appended.first?.kind {
            #expect(payload.rawType == AgentChatTranscriptTailer.oversizedRecordRawType)
        } else {
            Issue.record("expected an oversized row")
        }
    }
}

@Suite("Agent chat artifact index builds", .timeLimit(.minutes(2)))
struct AgentChatArtifactIndexBuildTests {
    private func makeFile(sparseBytes: UInt64 = 0, contents: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-index-\(UUID().uuidString).jsonl")
        try Data(contents.utf8).write(to: url)
        if sparseBytes > 0 {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: sparseBytes)
            try handle.close()
        }
        return url
    }

    @Test("concurrent misses for one session share one build")
    func concurrentMissesShareOneBuild() async throws {
        let url = try makeFile(sparseBytes: 2 * 1024 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = AgentChatArtifactIndex()
        let path = url.path
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    _ = try await index.snapshot(
                        sessionID: "session",
                        agentKind: .codex,
                        transcriptPath: path,
                        workingDirectory: nil
                    )
                }
            }
            while let result = await group.nextResult() {
                #expect(throws: Never.self) { try result.get() }
            }
        }
        #expect(await index.startedBuildCount == 1)
    }

    @Test("an unchanged transcript answers from the cache")
    func unchangedTranscriptUsesCache() async throws {
        let url = try makeFile(contents: "{}\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = AgentChatArtifactIndex()
        for _ in 0..<2 {
            _ = try await index.snapshot(
                sessionID: "session",
                agentKind: .codex,
                transcriptPath: url.path,
                workingDirectory: nil
            )
        }
        #expect(await index.startedBuildCount == 1)
    }

    /// Waits until `count` requests have joined a build, failing after a
    /// deadline instead of hanging when one answered from the cache.
    private func waitForRequests(_ count: Int, on index: AgentChatArtifactIndex) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while await index.waitingRequestCount < count {
            guard ContinuousClock.now < deadline else {
                let joined = await index.waitingRequestCount
                Issue.record("only \(joined) of \(count) requests joined a build before the deadline")
                return
            }
            await Task.yield()
        }
    }

    @Test("one cancelled request doesn't fail another waiting on the same build")
    func cancelledWaiterLeavesOthers() async throws {
        let url = try makeFile(sparseBytes: 64 * 1024 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = AgentChatArtifactIndex()
        let path = url.path
        let request: @Sendable () async throws -> AgentChatArtifactIndex.Snapshot = {
            try await index.snapshot(
                sessionID: "session",
                agentKind: .codex,
                transcriptPath: path,
                workingDirectory: nil
            )
        }
        let kept = Task { try await request() }
        let cancelled = Task { try await request() }
        await waitForRequests(2, on: index)
        cancelled.cancel()
        _ = try await kept.value
        #expect(await index.startedBuildCount == 1)
    }

    @Test("the last waiter leaving cancels the build, and nothing is cached")
    func lastWaiterCancelsBuild() async throws {
        let url = try makeFile(sparseBytes: 64 * 1024 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = AgentChatArtifactIndex()
        let path = url.path
        let request = Task {
            try await index.snapshot(
                sessionID: "session",
                agentKind: .codex,
                transcriptPath: path,
                workingDirectory: nil
            )
        }
        await waitForRequests(1, on: index)
        request.cancel()
        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        #expect(await index.waitingRequestCount == 0)
    }
}

@Suite("Transcript line assembler")
struct TranscriptLineAssemblerTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test("a line split across chunks comes out whole, once")
    func splitAcrossChunks() {
        var assembler = TranscriptLineAssembler(maxRecordBytes: 100)
        #expect(assembler.consume(data("ab")) == [])
        #expect(assembler.consume(data("c\nd\ne")) == [.record("abc"), .record("d")])
        #expect(assembler.consume(data("\n")) == [.record("e")])
    }

    @Test("a record over the limit is dropped across chunks and consumes one line")
    func oversizedAcrossChunks() {
        var assembler = TranscriptLineAssembler(maxRecordBytes: 4)
        #expect(assembler.consume(data("abc")) == [])
        #expect(assembler.consume(data("defg")) == [])
        #expect(assembler.consume(data("hij\nok\n")) == [.oversized, .record("ok")])
    }

    @Test("a record exactly at the limit is kept")
    func exactlyAtLimit() {
        var assembler = TranscriptLineAssembler(maxRecordBytes: 4)
        #expect(assembler.consume(data("abcd\n")) == [.record("abcd")])
    }

    @Test("a fragment from the first read continues, and an oversized one is not read")
    func seededFragment() {
        var kept = TranscriptLineAssembler(maxRecordBytes: 10, fragmentByteCount: 2, fragment: { Data("ab".utf8) })
        #expect(kept.consume(data("c\n")) == [.record("abc")])

        var discarded = TranscriptLineAssembler(maxRecordBytes: 10, fragmentByteCount: 50, fragment: {
            Issue.record("an oversized fragment must not be read")
            return Data()
        })
        #expect(discarded.consume(data("tail\nnext\n")) == [.oversized, .record("next")])
    }
}

extension AgentChatArtifactIndex {
    /// Requests waiting on any build, so a test can act once they have joined.
    var waitingRequestCount: Int {
        builds.values.reduce(0) { $0 + $1.waiterCount }
    }
}
