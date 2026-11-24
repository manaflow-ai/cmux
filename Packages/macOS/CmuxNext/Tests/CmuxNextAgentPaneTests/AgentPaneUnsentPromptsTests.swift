import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-11-11: "when restarting ALL MY ... UNSENT ... GOT DELETED". The store of prompts no
/// agent took keeps every one across a relaunch, and never writes over a file it could not read.
@Suite struct AgentPaneUnsentPromptsTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "unsent-prompts-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func record(_ id: String, _ text: String, refused: Bool) -> JSONValue {
        var body: [String: JSONValue] = ["promptId": .string(id), "input": .string(text), "attachments": .array([]), "at": .number(1)]
        if refused { body["failure"] = .object(["code": .string("remote.local_claude_session")]) }
        return .object(body)
    }

    /// A clock the test moves by hand.
    private nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { instant } }
        func advance(_ by: TimeInterval) { lock.withLock { instant = instant.addingTimeInterval(by) } }
    }

    private func ids(_ prompts: [JSONValue]) -> [String] {
        prompts.compactMap { if case .object(let body) = $0, case .string(let id)? = body["promptId"] { id } else { nil } }
    }

    @Test func aColdRestartKeepsEveryRefusedAndPendingPrompt() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = AgentPaneUnsentPrompts(directory: dir)
        let n = 5
        for i in 0..<n {
            #expect(await before.put(record("r\(i)", "refused \(i)", refused: true), for: "chat"))
            #expect(await before.put(record("p\(i)", "pending \(i)", refused: false), for: "chat"))
        }
        // A new process: a fresh store on the same folder.
        let after = AgentPaneUnsentPrompts(directory: dir)
        let kept = await after.prompts(for: "chat")
        #expect(Set(ids(kept)) == Set((0..<n).flatMap { ["r\($0)", "p\($0)"] }))
        #expect(await after.prompts(for: "another chat").isEmpty)
    }

    @Test func onlyRemoveTakesAPromptOut() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentPaneUnsentPrompts(directory: dir)
        await store.put(record("a", "one", refused: true), for: "chat")
        await store.put(record("b", "two", refused: true), for: "chat")
        // A later record of the same prompt (its refusal) replaces it, never adds a copy.
        await store.put(record("a", "one", refused: false), for: "chat")
        #expect(ids(await store.prompts(for: "chat")) == ["b", "a"])
        await store.remove("b", for: "chat")
        #expect(ids(await AgentPaneUnsentPrompts(directory: dir).prompts(for: "chat")) == ["a"])
    }

    /// No age limit: an old prompt stays when a new one of its chat is written (review P1-F2).
    @Test func anOldPromptStaysWhenItsChatIsWrittenAgain() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let store = AgentPaneUnsentPrompts(directory: dir, now: { clock.now })
        await store.put(record("old", "from long ago", refused: true), for: "chat")
        await store.settle()
        clock.advance(365 * 24 * 60 * 60)
        await store.put(record("new", "today", refused: false), for: "chat")
        #expect(ids(await AgentPaneUnsentPrompts(directory: dir).prompts(for: "chat")) == ["old", "new"])
    }

    @Test func aCorruptFileIsSetAsideAndReadFromItsBackupNeverOverwritten() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentPaneUnsentPrompts(directory: dir)
        await store.put(record("a", "one", refused: true), for: "chat")
        await store.put(record("b", "two", refused: true), for: "chat")
        let file = store.file(for: "chat")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: file)

        let fresh = AgentPaneUnsentPrompts(directory: dir)
        // The backup (the file before the last write) still has the first prompt.
        #expect(ids(await fresh.prompts(for: "chat")) == ["a"])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        let aside = try #require(names.first { $0.contains(".unreadable-") })
        // The unreadable bytes are kept as they were, beside it.
        #expect(try Data(contentsOf: store.directory.appending(path: aside)) == garbage)
        // A write after that starts from what could be read, never from an empty list.
        await fresh.put(record("c", "three", refused: true), for: "chat")
        #expect(ids(await fresh.prompts(for: "chat")) == ["a", "c"])
    }

    @Test func aFileThatCannotBeMovedAsideIsNeverWrittenOver() async throws {
        let dir = directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: AgentPaneUnsentPrompts.directoryName).path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = AgentPaneUnsentPrompts(directory: dir)
        await store.put(record("a", "one", refused: true), for: "chat")
        let file = store.file(for: "chat")
        let garbage = Data("locked and broken".utf8)
        try garbage.write(to: file)
        // The folder is read-only: the file can be neither moved aside nor replaced.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.directory.path)
        let locked = AgentPaneUnsentPrompts(directory: dir)
        #expect(await locked.put(record("b", "two", refused: true), for: "chat") == false)
        #expect(try Data(contentsOf: file) == garbage)
    }

    @Test func thePageOpsRoundTrip() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentPaneUnsentPrompts(directory: dir)
        let put = await AgentPaneUnsentPrompts.reply(to: "chat.unsentPrompt.put",
                                                     params: .object(["sessionId": .string("s"), "prompt": record("a", "hi", refused: true)]), store: store)
        #expect(put == .success(.null))
        let got = await AgentPaneUnsentPrompts.reply(to: "chat.unsentPrompts.get", params: .object(["sessionId": .string("s")]), store: store)
        guard case .success(.object(let body)) = got, case .array(let prompts)? = body["prompts"] else {
            Issue.record("no prompts: \(got)")
            return
        }
        #expect(ids(prompts) == ["a"])
        let removed = await AgentPaneUnsentPrompts.reply(to: "chat.unsentPrompt.remove",
                                                         params: .object(["sessionId": .string("s"), "promptId": .string("a")]), store: store)
        #expect(removed == .success(.null))
        #expect(await store.prompts(for: "s").isEmpty)
    }
}
