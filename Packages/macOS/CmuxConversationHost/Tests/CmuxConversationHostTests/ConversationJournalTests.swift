import Foundation
import Testing
import CmuxConversation
@testable import CmuxConversationHost

@Suite struct ConversationJournalTests {
    @Test func replayReadsOnlyRequestedPageAndKeepsSequence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ConversationJournal(directory: root)
        for sequence in 1...8 {
            try await journal.append(event(sequence: ConversationCursor(sequence)))
        }
        let page = try await journal.events(after: 3, limit: 2)
        #expect(page.map(\.sequence) == [4, 5])
        #expect(await journal.lastSequence == 8)
    }

    @Test func incompleteFinalLineIsTruncatedBeforeNextAppend() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ConversationJournal(directory: root)
        try await journal.append(event(sequence: 1))
        let url = root.appendingPathComponent("events.jsonl")
        var data = try Data(contentsOf: url)
        data.append(contentsOf: Data("{\"truncated\"".utf8))
        try data.write(to: url, options: [.atomic])
        let recovered = try ConversationJournal(directory: root)
        try await recovered.append(event(sequence: 2))
        let events = try await recovered.events(after: 0)
        #expect(events.map(\.sequence) == [1, 2])
    }

    @Test func corruptEarlierLineFailsClosed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ConversationJournal(directory: root)
        try await journal.append(event(sequence: 1))
        try await journal.append(event(sequence: 2))
        let url = root.appendingPathComponent("events.jsonl")
        var data = try Data(contentsOf: url)
        if let newline = data.firstIndex(of: 10) { data.replaceSubrange(0..<newline, with: Data("corrupt".utf8)) }
        try data.write(to: url, options: [.atomic])
        #expect(throws: (any Error).self) { _ = try ConversationJournal(directory: root) }
    }

    private func event(sequence: ConversationCursor) -> ConversationEvent {
        ConversationEvent(sessionID: .init(rawValue: "journal-test"), sequence: sequence, generation: "generation", kind: .unknown("test"), rawPayload: .object(["sequence": .number(String(sequence))]))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-conversation-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
