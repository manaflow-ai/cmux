import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileHost

/// Regressions for https://github.com/manaflow-ai/cmux/issues/31300: the first
/// read of a transcript must be bounded in bytes, not only in lines.
@Suite("Agent chat transcript tailer bounds", .timeLimit(.minutes(2)))
struct AgentChatTranscriptTailerBoundsTests {
    private static let mebibyte = 1024 * 1024

    private func codexLine(_ text: String) -> String {
        let object: [String: Any] = [
            "timestamp": "2026-06-11T21:38:05.381Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeTranscript(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailer-bounds-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func makeTailer(url: URL) -> AgentChatTranscriptTailer {
        AgentChatTranscriptTailer(sessionID: "session", agentKind: .codex, path: url.path) { _ in }
    }

    private func isOversizedRow(_ message: ChatMessage) -> Bool {
        if case .unsupported = message.kind { return true }
        return false
    }

    @Test("one valid record over the size limit is skipped with a visible row and keeps its seq")
    func oversizedRecordKeepsSeq() async throws {
        let huge = codexLine(String(repeating: "x", count: 9 * Self.mebibyte))
        let url = try makeTranscript(codexLine("before") + "\n" + huge + "\n" + codexLine("after") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let tailer = makeTailer(url: url)
        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 100)
        await tailer.stop()

        #expect(page.messages.map(\.seq) == [0, 1, 2])
        #expect(isOversizedRow(page.messages[1]))
        #expect(!isOversizedRow(page.messages[2]))
        #expect(page.hasMore == false)
    }

    @Test("few lines holding many bytes stop at the byte budget with absolute seqs and honest paging")
    func byteBudgetBoundsFewLongLines() async throws {
        // Each record is under the single-record limit; together they are far
        // over the window, and far under the 2,000 line limit.
        let record = codexLine(String(repeating: "y", count: 2 * Self.mebibyte))
        let lineCount = 40
        let contents = String(repeating: record + "\n", count: lineCount)
        let url = try makeTranscript(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        let tailer = makeTailer(url: url)
        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 100)
        await tailer.stop()

        let seqs = page.messages.map(\.seq)
        #expect(seqs.last == lineCount - 1)
        #expect(seqs.count <= 16)
        #expect((seqs.first ?? 0) > 0)
        #expect(seqs == Array((seqs.first ?? 0)...(lineCount - 1)))
        #expect(page.hasMore == true)
    }

    @Test("a small transcript loads whole, pages by seq and reports no older history")
    func smallTranscriptIsUnchanged() async throws {
        let contents = (0..<5).map { codexLine("line \($0)") + "\n" }.joined()
        let url = try makeTranscript(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        let tailer = makeTailer(url: url)
        await tailer.start()
        let newest = await tailer.history(beforeSeq: nil, limit: 2)
        let older = await tailer.history(beforeSeq: 3, limit: 100)
        await tailer.stop()

        #expect(newest.messages.map(\.seq) == [3, 4])
        #expect(newest.hasMore == true)
        #expect(older.messages.map(\.seq) == [0, 1, 2])
        #expect(older.hasMore == false)
    }

    @Test("a trailing partial record joins the bytes appended after the first read")
    func trailingPartialCompletesOnAppend() async throws {
        let last = codexLine("completed later")
        let splitAt = last.index(last.startIndex, offsetBy: last.count / 2)
        let url = try makeTranscript(codexLine("first") + "\n" + String(last[..<splitAt]))
        defer { try? FileManager.default.removeItem(at: url) }

        let (batches, continuation) = AsyncStream.makeStream(of: AgentChatTranscriptTailer.Batch.self)
        let tailer = AgentChatTranscriptTailer(sessionID: "session", agentKind: .codex, path: url.path) { batch in
            continuation.yield(batch)
        }
        await tailer.start()
        let initial = await tailer.history(beforeSeq: nil, limit: 100)
        #expect(initial.messages.map(\.seq) == [0])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(last[splitAt...]) + "\n").utf8))
        try handle.close()

        var appended: [ChatMessage] = []
        for await batch in batches {
            appended = batch.appended
            break
        }
        await tailer.stop()
        continuation.finish()
        #expect(appended.map(\.seq) == [1])
    }

    @Test("an atomically replaced transcript resets the seq space")
    func replacementResets() async throws {
        let url = try makeTranscript((0..<3).map { codexLine("old \($0)") + "\n" }.joined())
        defer { try? FileManager.default.removeItem(at: url) }

        let (batches, continuation) = AsyncStream.makeStream(of: AgentChatTranscriptTailer.Batch.self)
        let tailer = AgentChatTranscriptTailer(sessionID: "session", agentKind: .codex, path: url.path) { batch in
            continuation.yield(batch)
        }
        await tailer.start()

        try (codexLine("new") + "\n").write(to: url, atomically: true, encoding: .utf8)

        var didReset = false
        for await batch in batches where batch.didReset {
            didReset = true
            break
        }
        let page = await tailer.history(beforeSeq: nil, limit: 100)
        await tailer.stop()
        continuation.finish()
        #expect(didReset)
        #expect(page.messages.map(\.seq) == [0])
    }
}
