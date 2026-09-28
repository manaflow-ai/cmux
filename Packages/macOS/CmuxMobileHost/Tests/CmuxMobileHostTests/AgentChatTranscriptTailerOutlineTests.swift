import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileHost

@Suite("Transcript tailer outline")
struct AgentChatTranscriptTailerOutlineTests {
    private static func claudeUser(_ uuid: String, _ text: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-09-28T10:00:00Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    private static func claudeAssistant(_ uuid: String, _ text: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","timestamp":"2026-09-28T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private static func toolNoise(_ uuid: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t-\#(uuid)","name":"Bash","input":{"command":"ls"}}]}}"#
    }

    private func transcript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailer-outline-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("the outline covers prompts older than the backfill window")
    func outlineCoversHeadBeyondBackfill() async throws {
        var lines: [String] = []
        for turn in 0..<6 {
            lines.append(Self.claudeUser("u\(turn)", "prompt \(turn)"))
            lines.append(Self.claudeAssistant("a\(turn)", "reply \(turn)"))
            lines.append(contentsOf: (0..<5).map { Self.toolNoise("n\(turn)-\($0)") })
        }
        let url = try transcript(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        // The backfill window holds only the last turn.
        let tailer = AgentChatTranscriptTailer(
            sessionID: "s",
            agentKind: .claude,
            path: url.path,
            maxInitialLines: 7,
            onBatch: { _ in }
        )
        await tailer.start()
        defer { Task { await tailer.stop() } }

        let entries = await tailer.outlineEntries
        #expect(entries.map(\.title) == (0..<6).map { "prompt \($0)" })
        #expect(entries.map(\.replyPreview) == (0..<6).map { "reply \($0)" })
        #expect(entries.map(\.seq) == (0..<6).map { $0 * 7 })
        #expect(await tailer.isOutlineHeadTruncated == false)
        let cached = await tailer.history(beforeSeq: nil, limit: 100).messages
        #expect(!cached.contains { $0.id == "u0" })
    }

    @Test("a head larger than the scan cap reports a truncated outline")
    func headScanCapTruncates() async throws {
        let lines = (0..<20).flatMap { turn in
            [Self.claudeUser("u\(turn)", "prompt \(turn)"), Self.claudeAssistant("a\(turn)", "reply \(turn)")]
        }
        let url = try transcript(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = AgentChatTranscriptTailer(
            sessionID: "s",
            agentKind: .claude,
            path: url.path,
            maxInitialLines: 2,
            outlineHeadScanByteCap: 600,
            onBatch: { _ in }
        )
        await tailer.start()
        defer { Task { await tailer.stop() } }

        let entries = await tailer.outlineEntries
        #expect(await tailer.isOutlineHeadTruncated)
        #expect(entries.last?.title == "prompt 19")
        #expect(entries.count < 20)
        #expect(entries.count > 1)
    }

    @Test("prompts appended while tailing extend the outline")
    func liveAppendsExtendOutline() async throws {
        let url = try transcript([Self.claudeUser("u0", "first prompt")])
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = AgentChatTranscriptTailer(sessionID: "s", agentKind: .claude, path: url.path, onBatch: { _ in })
        await tailer.start()
        defer { Task { await tailer.stop() } }
        #expect(await tailer.outlineEntries.map(\.title) == ["first prompt"])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.claudeAssistant("a0", "on it") + "\n" + Self.claudeUser("u1", "second prompt") + "\n").utf8))
        try handle.close()

        var titles: [String] = []
        for _ in 0..<100 {
            titles = await tailer.outlineEntries.map(\.title)
            if titles.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(titles == ["first prompt", "second prompt"])
        #expect(await tailer.outlineEntries.first?.replyPreview == "on it")
    }
}
