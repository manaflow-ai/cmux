import Foundation
import Testing

@testable import CmuxAgentConversation

/// Behavioral tests for ``TailingTranscriptConversationSource`` against a real
/// temp-file transcript: append → incremental events, truncate/rotate →
/// ``ConversationEvent/truncated`` plus a fresh snapshot, and continued
/// tailing after rotation.
///
/// The tests are event-driven (no sleeps): each step awaits the next emitted
/// event, and the suite-level time limit guards against a hang if the watcher
/// misses a change.
@Suite(.timeLimit(.minutes(1))) struct TailingTranscriptConversationSourceTests {
    /// A Claude-format user line with the given uuid and text.
    private func userLine(id: String, text: String) -> String {
        #"{"parentUuid":null,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"\#(id)","timestamp":"2026-06-02T11:54:43.294Z","sessionId":"sess-tail"}"#
    }

    /// The flattened text blocks of the given messages, for assertions
    /// (the parser assigns positional message ids, so text is the stable key).
    private func texts(of messages: [Message]) -> [String] {
        messages.flatMap { message in
            message.blocks.compactMap { block -> String? in
                if case let .text(text) = block { return text }
                return nil
            }
        }
    }

    /// Creates a unique temp transcript containing the given lines.
    private func makeTranscript(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")
        try (lines.map { $0 + "\n" }.joined()).write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// Appends one line to the transcript through a fresh write handle.
    private func append(line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    @Test func appendedLinesEmitUpserts() async throws {
        let url = try makeTranscript(lines: [userLine(id: "u1", text: "first")])
        let source = TailingTranscriptConversationSource(
            agentKind: .claudeCode,
            sessionId: "sess-tail",
            transcriptURL: url
        )
        var iterator = source.events.makeAsyncIterator()

        // Initial snapshot arrives after the watcher is attached, so an append
        // made after this point is guaranteed to be observed.
        guard case let .snapshot(initial) = try #require(await iterator.next()) else {
            Issue.record("expected initial snapshot")
            return
        }
        #expect(texts(of: initial.messages) == ["first"])

        try append(line: userLine(id: "u2", text: "second"), to: url)

        guard case let .upsert(messages, seq) = try #require(await iterator.next()) else {
            Issue.record("expected upsert after append")
            return
        }
        #expect(texts(of: messages) == ["second"])
        #expect(seq > initial.seq)
    }

    @Test func rewrittenTranscriptEmitsTruncatedThenSnapshot() async throws {
        let url = try makeTranscript(lines: [
            userLine(id: "u1", text: "first"),
            userLine(id: "u2", text: "second"),
        ])
        let source = TailingTranscriptConversationSource(
            agentKind: .claudeCode,
            sessionId: "sess-tail",
            transcriptURL: url
        )
        var iterator = source.events.makeAsyncIterator()

        guard case let .snapshot(initial) = try #require(await iterator.next()) else {
            Issue.record("expected initial snapshot")
            return
        }
        #expect(initial.messages.count == 2)

        // Atomic rewrite replaces the inode (rename onto the path), exercising
        // the delete/rename re-attach path on top of truncation detection.
        try (userLine(id: "r1", text: "rewritten") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        guard case .truncated = try #require(await iterator.next()) else {
            Issue.record("expected truncated after rewrite")
            return
        }
        guard case let .snapshot(fresh) = try #require(await iterator.next()) else {
            Issue.record("expected fresh snapshot after truncated")
            return
        }
        #expect(texts(of: fresh.messages) == ["rewritten"])
        #expect(fresh.seq > initial.seq)

        // The watcher must have re-attached to the new inode: a further append
        // still produces an event.
        try append(line: userLine(id: "r2", text: "post-rotation"), to: url)
        guard case let .upsert(messages, _) = try #require(await iterator.next()) else {
            Issue.record("expected upsert after post-rotation append")
            return
        }
        #expect(texts(of: messages) == ["post-rotation"])
    }

    @Test func missingTranscriptYieldsEmptySnapshotAndFinishes() async throws {
        let source = TailingTranscriptConversationSource(
            agentKind: .claudeCode,
            sessionId: "sess-none",
            transcriptURL: nil
        )
        var iterator = source.events.makeAsyncIterator()
        guard case let .snapshot(empty) = try #require(await iterator.next()) else {
            Issue.record("expected empty snapshot")
            return
        }
        #expect(empty.messages.isEmpty)
        #expect(await iterator.next() == nil)
    }

    @Test func fileCreatedAfterSubscribeIsPickedUpViaDirectoryWatch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")

        let source = TailingTranscriptConversationSource(
            agentKind: .claudeCode,
            sessionId: "sess-tail",
            transcriptURL: url
        )
        var iterator = source.events.makeAsyncIterator()

        guard case let .snapshot(initial) = try #require(await iterator.next()) else {
            Issue.record("expected initial snapshot")
            return
        }
        #expect(initial.messages.isEmpty)

        try (userLine(id: "u1", text: "born late") + "\n")
            .write(to: url, atomically: false, encoding: .utf8)

        guard case let .upsert(messages, _) = try #require(await iterator.next()) else {
            Issue.record("expected upsert once the file appears")
            return
        }
        #expect(texts(of: messages) == ["born late"])
    }
}
