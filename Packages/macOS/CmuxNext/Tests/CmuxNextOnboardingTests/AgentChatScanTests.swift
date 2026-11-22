import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The chat scan over a fixture home: Claude Code and Codex chats, their
/// ids, titles and typed-prompt counts, newest first, under kept folders.
@Suite struct AgentChatScanTests {
    let home: URL
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400
    let claudeID = "0a1b2c3d-1111-4222-8333-444455556666"
    let codexID = "01999a2b-3c4d-7e5f-8a9b-0c1d2e3f4a5b"

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "chat-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: "code/app"), withIntermediateDirectories: true)
    }

    var app: String { home.appending(path: "code/app").standardizedFileURL.path }

    func write(_ relative: String, _ records: [[String: Any]], age: Double) throws {
        let file = home.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now - age * day], ofItemAtPath: file.path)
    }

    func claudeUser(_ content: Any, meta: Bool = false, flag: String? = nil) -> [String: Any] {
        var record: [String: Any] = ["type": "user", "cwd": app, "isMeta": meta, "message": ["role": "user", "content": content]]
        if let flag { record[flag] = true }
        return record
    }

    /// A session file name: Claude Code names each session's file by its UUID.
    func uuid(_ index: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", index) }

    func scan() -> [AgentChat] { AgentChatScan(projects: AgentProjectScan(home: home)).run() }

    /// Only typed prompts count: not meta, sidechain or compact-summary
    /// records, tool results or injected `<...>` context. The first prompt
    /// names the chat; a summary record (it may describe another session) doesn't.
    @Test func claudeChatsCountTypedPromptsAndAreNamedByTheFirst() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write(".claude/projects/-app/\(claudeID).jsonl", [
            claudeUser("<command-name>/clear</command-name>"),
            claudeUser("Caveat: injected", meta: true),
            claudeUser("Fix the flaky login test\nIt fails on CI"),
            ["type": "assistant", "cwd": app, "message": ["role": "assistant", "content": "On it"]],
            claudeUser([["type": "tool_result", "content": "ok"]]),
            claudeUser([["type": "text", "text": "Now add a regression test"]]),
            claudeUser("A subagent's task", flag: "isSidechain"),
            claudeUser("This session is being continued from a previous conversation", flag: "isCompactSummary"),
        ], age: 0)
        let chats = scan()
        #expect(chats.count == 1)
        #expect(chats.first?.sessionID == claudeID && chats.first?.app == .claudeCode)
        #expect(chats.first?.title == "Fix the flaky login test" && chats.first?.prompts == 2)
        #expect(chats.first?.folder.path == app && chats.first?.adoptHarness == "claude")

        try write(".claude/projects/-app/\(claudeID).jsonl", [["type": "summary", "summary": "Another chat"], claudeUser("Fix it")], age: 0)
        #expect(scan().first?.title == "Fix it")
        // A subagent transcript sits beside the sessions; adopt can't resume it.
        try write(".claude/projects/-app/agent-1a2b3c4d.jsonl", [claudeUser("Search the repo", flag: "isSidechain")], age: 0)
        #expect(scan().map(\.sessionID) == [claudeID])
    }

    /// Codex writes each prompt as an event and again as a response item;
    /// each counts once. A file with no events (older Codex) counts items.
    @Test func codexChatsCountEachPromptOnce() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        func item(_ text: String) -> [String: Any] {
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
        }
        func event(_ text: String) -> [String: Any] { ["type": "event_msg", "payload": ["type": "user_message", "message": text]] }
        try write(".codex/sessions/2026/10/01/rollout-2026-10-01T09-00-00-\(codexID).jsonl", [
            ["type": "session_meta", "payload": ["id": codexID, "cwd": app]],
            item("<environment_context>cwd</environment_context>"),
            item("Rename the config loader"), event("Rename the config loader"),
            item("Run the tests"), event("Run the tests"),
        ], age: 1)
        try write(".codex/sessions/2026/09/01/rollout-2026-09-01T09-00-00-old.jsonl", [
            ["type": "session_meta", "payload": ["id": "old", "cwd": app]],
            item("Older Codex prompt"), item("Second"), item("Third"),
        ], age: 30)
        let chats = scan()
        #expect(chats.map(\.sessionID) == [codexID, "old"])
        #expect(chats[0].title == "Rename the config loader" && chats[0].prompts == 2 && chats[0].adoptHarness == "codex")
        #expect(chats[1].title == "Older Codex prompt" && chats[1].prompts == 3)
    }

    /// Newest first, capped at `limit`; no chat without a prompt, without a
    /// cwd, or under a folder the projects step leaves out.
    @Test func newestFirstCappedAndOnlyUnderKeptFolders() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for age in 0..<3 {
            try write(".claude/projects/-app/\(uuid(age)).jsonl", [claudeUser("Prompt \(age)")], age: Double(age))
        }
        try write(".claude/projects/-app/\(uuid(7)).jsonl", [claudeUser("<only context>")], age: 0)
        try write(".claude/projects/-gone/\(uuid(8)).jsonl",
                  [["type": "user", "cwd": home.appending(path: "code/gone").path, "message": ["content": "Hi"]]], age: 0)
        try write(".claude/projects/-home/\(uuid(9)).jsonl",
                  [["type": "user", "cwd": home.path, "message": ["content": "Hi"]]], age: 0)
        #expect(scan().map(\.sessionID) == [uuid(0), uuid(1), uuid(2)])
        var capped = AgentChatScan(projects: AgentProjectScan(home: home))
        capped.limit = 2
        #expect(capped.run().map(\.sessionID) == [uuid(0), uuid(1)])
    }
}
