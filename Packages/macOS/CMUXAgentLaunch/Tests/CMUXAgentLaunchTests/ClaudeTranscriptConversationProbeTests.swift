import Foundation
import Testing
@testable import CMUXAgentLaunch

/// The probe reads a transcript in 64 KiB chunks; these cases put lines across, on and after
/// chunk boundaries.
@Suite struct ClaudeTranscriptConversationProbeTests {
    private static let chunk = 64 * 1024

    /// A JSON record line of exactly `bytes` bytes, without its newline.
    private static func record(type: String, bytes: Int) -> String {
        let head = #"{"type":""# + type + #"","content":""#
        let tail = #""}"#
        return head + String(repeating: "x", count: bytes - head.utf8.count - tail.utf8.count) + tail
    }

    private func probe(_ body: String) throws -> Bool {
        let path = NSTemporaryDirectory() + "probe-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        return try ClaudeTranscriptConversationProbe.containsConversation(atPath: path)
    }

    @Test func findsARecordLongerThanFiveChunksAfterMetadata() throws {
        let metadata = Self.record(type: "ai-title", bytes: 300) + "\n"
            + Self.record(type: "agent-name", bytes: 200) + "\n"
        let user = Self.record(type: "user", bytes: 5 * Self.chunk + 1234)
        #expect(try probe(metadata + user + "\n"))
        #expect(try probe(metadata + Self.record(type: "attachment", bytes: 5 * Self.chunk + 1234) + "\n") == false)
    }

    /// The newline is the last byte of the first chunk, then the first byte of the second.
    @Test(arguments: [Self.chunk - 1, Self.chunk])
    func findsTheRecordAfterANewlineOnAChunkBoundary(firstLineBytes: Int) throws {
        let first = Self.record(type: "attachment", bytes: firstLineBytes) + "\n"
        #expect(try probe(first + Self.record(type: "assistant", bytes: 120) + "\n"))
        #expect(try probe(first + Self.record(type: "agent-name", bytes: 120) + "\n") == false)
    }

    @Test func readsAnUnterminatedFinalRecord() throws {
        let metadata = Self.record(type: "ai-title", bytes: Self.chunk + 17) + "\n"
        #expect(try probe(metadata + Self.record(type: "user", bytes: 3 * Self.chunk + 5)))
        #expect(try probe(metadata + Self.record(type: "ai-title", bytes: 3 * Self.chunk + 5)) == false)
        // A record still being written is not JSON yet.
        let partial = String(Self.record(type: "user", bytes: 3 * Self.chunk).dropLast(2))
        #expect(try probe(metadata + partial) == false)
    }
}
