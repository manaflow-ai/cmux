@testable import CmuxNextAgentPane
import Testing

/// C7's device-wide index uses `chats` rows rather than acpmux session summaries.
struct AcpmuxChatsProtocolTests {
    @Test func chatIndexRowsAreAcceptedAndRemainNewestFirst() {
        var chats = AcpmuxRecentChats()
        chats.reset(["ready": true, "chats": [
            ["key": "codex:new", "harness": "codex", "sessionId": "new", "title": "Newer", "updatedMs": 20, "cwd": "/repo"],
            ["key": "claude:old", "harness": "claude-code", "sessionId": "old", "title": "Older", "updatedMs": 10, "cwd": "/repo"],
        ]])
        #expect(chats.newest(10).map(\.id) == ["codex:new", "claude:old"])
    }

    @Test func removedChatKeyLeavesTheIncrementalList() {
        var chats = AcpmuxRecentChats()
        chats.reset(["ready": true, "chats": [
            ["key": "codex:a", "harness": "codex", "sessionId": "a", "title": "A", "updatedMs": 20],
            ["key": "codex:b", "harness": "codex", "sessionId": "b", "title": "B", "updatedMs": 10],
        ]])
        chats.apply(changed: ["kind": "removed", "key": "codex:a"])
        #expect(chats.newest(10).map(\.id) == ["codex:b"])
    }
}

struct AcpmuxChatsOpenPlanTests {
    @Test func terminalPlanPreservesArgvAndEnvironment() throws {
        let plan = try #require(AcpmuxChatOpenPlan(result: [
            "kind": "terminal", "cwd": "/repo",
            "terminal": ["argv": ["codex", "resume", "thread:1"], "env": ["CODEX_HOME": "/tmp/codex"]],
        ]))
        #expect(plan.action == .terminal(argv: ["codex", "resume", "thread:1"], env: ["CODEX_HOME": "/tmp/codex"], cwd: "/repo"))
    }

    @Test func missingFolderWinsBeforeOpenKind() throws {
        let plan = try #require(AcpmuxChatOpenPlan(result: [
            "kind": "readOnly", "needsFolder": ["reason": "Pick the project folder"],
            "readOnly": ["path": "/tmp/chat.jsonl"],
        ]))
        #expect(plan.action == .needsFolder(reason: "Pick the project folder"))
    }
}

struct AcpmuxChatsStoreTests {
    @Test func incrementalUpsertUsesUpdatedOrderAndSearchesMetadata() throws {
        var store = AcpmuxChatsStore()
        store.reset(["chats": [
            ["key": "codex:a", "harness": "codex", "sessionId": "a", "title": "Older", "updatedMs": 10, "cwd": "/repo/a", "accounts": ["work"]],
            ["key": "claude:b", "harness": "claude-code", "sessionId": "b", "title": "Newer", "updatedMs": 20, "cwd": "/repo/b", "accounts": ["personal"]],
        ]])
        store.apply(change: ["kind": "upsert", "key": "codex:a", "chat": [
            "key": "codex:a", "harness": "codex", "sessionId": "a", "title": "Latest", "updatedMs": 30, "cwd": "/repo/a", "accounts": ["work"],
        ]])
        #expect(store.chats.map(\.id) == ["codex:a", "claude:b"])
        #expect(store.filtered(query: "work").map(\.id) == ["codex:a"])
        #expect(store.filtered(query: "repo/b").map(\.id) == ["claude:b"])
    }
}
