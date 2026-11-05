import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// acpmux's "who else is working on these files" answer as a card (the Mac's `whoElseCalls.ts` and
/// `WhoElseCard.test.tsx` cases): which calls ask it, where the answer sits, and the card's wording.
@MainActor
@Suite struct WhoElseCallTests {
    static let answer: JSONValue = .object([
        "schema": .string(WhoElseCall.schema),
        "query": .object(["files": .array([.string("src/mux.rs")]), "fileCount": .number(1), "topic": .string("crate split")]),
        "sessions": .array([
            .object([
                "sessionId": .string("s-1"), "name": .string("crate-split"), "ref": .string("crate-split"),
                "harness": .string("codex"), "status": .string("running"), "live": .bool(true),
                "branch": .string("lane/crate-split"),
                "pullRequests": .array([.string("https://github.com/example/cmux/pull/36001")]),
                "agoMs": .number(4 * 60_000), "filesInCommon": .number(5), "editedInCommon": .number(2),
                "files": .array([
                    .object(["path": .string("src/mux.rs"), "edited": .bool(true), "at": .number(1)]),
                    .object(["path": .string("src/server.rs"), "edited": .bool(true)]),
                    .object(["path": .string("Cargo.toml"), "edited": .bool(false)]),
                    .object(["path": .string("   ")]),
                ]),
                "sameWorktree": .bool(true), "sameBranch": .bool(false), "topicWords": .array([]),
            ]),
            .object([
                "sessionId": .string("s-2"), "name": .string("mux-rs"), "ref": .string("big-red/mux-rs"), "host": .string("big-red"),
                "harness": .string("opencode"), "status": .string("idle"), "live": .bool(false),
                "agoMs": .number(26 * 3_600_000), "filesInCommon": .number(0), "topicWords": .array([.string("crate"), .string("split")]),
            ]),
            .string("not a session"),
        ]),
        "more": .number(2),
        "unreached": .array([.object(["host": .string("cosmic-gray"), "error": .string("no answer in 5 s")]), .object([:])]),
        "lines": .array([]),
    ])

    static func text(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func call(title: String, status: ACPToolCall.Status = .completed, kind: ACPToolCall.Kind = .other,
                     input: JSONValue? = nil, output: JSONValue? = nil, content: String? = nil) -> ACPToolCall {
        ACPToolCall(id: "c1", title: title, kind: kind, status: status, content: content.map { [.content(.text($0))] } ?? [],
                    rawInput: input, rawOutput: output)
    }

    // MARK: Which calls ask

    @Test func claudesMcpToolWithStructuredContentReadsTheAnswer() throws {
        let output: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("…")])]),
                                         "structuredContent": Self.answer])
        let call = try #require(WhoElseCall(Self.call(title: "mcp__acpmux__who_else", output: output)))
        #expect(!call.pending)
        let answer = try #require(call.answer)
        #expect(answer.sessions.map(\.name) == ["crate-split", "mux-rs"])
        #expect(answer.more == 2)
        #expect(answer.unreached == ["cosmic-gray"])
        #expect(answer.files == ["src/mux.rs"])
        #expect(answer.fileCount == 1)
        #expect(answer.topic == "crate split")
        let first = answer.sessions[0]
        #expect(first.live && first.sameWorktree && !first.sameBranch)
        #expect(first.files.map(\.path) == ["src/mux.rs", "src/server.rs", "Cargo.toml"])
        #expect(first.files.map(\.edited) == [true, true, false])
        #expect(first.files[0].at == 1)
        #expect(answer.sessions[1].host == "big-red")
        #expect(answer.sessions[1].ref == "big-red/mux-rs")
    }

    @Test func codexMcpCallAndTheCmuxFoldedNameAsk() throws {
        let codex = Self.call(title: "acpmux.who_else call",
                              input: .object(["server": .string("acpmux"), "tool": .string("who_else"), "arguments": .object([:])]),
                              output: Self.answer)
        #expect(WhoElseCall(codex)?.answer?.sessions.count == 2)
        #expect(WhoElseCall(Self.call(title: "acpmux_who_else", output: Self.answer)) != nil)
        // Another server's tool of the same name is not acpmux's.
        let other = Self.call(title: "mcp__github__who_else", output: Self.answer)
        #expect(WhoElseCall(other) == nil)
        let bare = Self.call(title: "who_else",
                             input: .object(["server": .string("github"), "tool": .string("who_else"), "arguments": .object([:])]),
                             output: Self.answer)
        #expect(WhoElseCall(bare) == nil)
    }

    @Test func aPullRequestLinkIsOnlyAnHttpsUrl() {
        #expect(WhoElseCall.isPullLink("https://github.com/o/r/pull/2"))
        #expect(!WhoElseCall.isPullLink("javascript:alert(1)"))
        #expect(!WhoElseCall.isPullLink("data:text/html,x"))
        #expect(!WhoElseCall.isPullLink("http://github.com/o/r/pull/2"))
        #expect(!WhoElseCall.isPullLink("https://me:pw@github.com/o/r/pull/2"))
    }

    @Test func aShellCallCountsOnlyWithJson() throws {
        let json = Self.call(title: "Run acpmux", kind: .execute,
                             input: .object(["command": .string("cd /x && acpmux --json who-else src/mux.rs")]), content: Self.text(Self.answer))
        #expect(WhoElseCall(json)?.answer?.sessions.count == 2)
        let plain = Self.call(title: "Run acpmux", kind: .execute,
                              input: .object(["command": .string("acpmux who-else src/mux.rs")]), content: Self.text(Self.answer))
        #expect(WhoElseCall(plain) == nil)
        let unrelated = Self.call(title: "Run echo", kind: .execute,
                                  input: .object(["command": .string("echo acpmux --json who-else")]), content: Self.text(Self.answer))
        #expect(WhoElseCall(unrelated) == nil)
    }

    @Test func runningIsLookingAndFinishedWithoutAnAnswerIsAToolRow() {
        let running = WhoElseCall(Self.call(title: "mcp__acpmux__who_else", status: .inProgress))
        #expect(running?.pending == true)
        #expect(running?.answer == nil)
        #expect(WhoElseCall(Self.call(title: "mcp__acpmux__who_else", status: .failed, content: "who_else needs the chat's session")) == nil)
    }

    // MARK: Where the answer sits

    @Test func theAnswerAsAJsonStringInAnMcpTextBlockOrEnvelope() throws {
        // An MCP result whose text block holds the answer as JSON.
        let mcpResult: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string(Self.text(Self.answer))])])])
        #expect(WhoElseCall(Self.call(title: "mcp__acpmux__who_else", output: mcpResult))?.answer?.sessions.count == 2)
        // A cmux_exec envelope with the answer as a JSON string.
        let envelope: JSONValue = .object(["value": .string(Self.text(Self.answer))])
        #expect(WhoElseCall(Self.call(title: "mcp__cmux__who_else", output: envelope))?.answer?.sessions.count == 2)
        // The answer only in the call's content text.
        #expect(WhoElseCall(Self.call(title: "mcp__acpmux__who_else", content: Self.text(Self.answer)))?.answer?.more == 2)
    }

    @Test func tooDeepOrTheWrongSchemaFindsNoAnswer() {
        var deep = Self.answer
        for _ in 0..<6 { deep = .object(["result": deep]) }
        #expect(WhoElseCall.findAnswer(deep, depth: 0) == nil)
        let wrong: JSONValue = .object(["schema": .string("acpmux.who-else.v0"), "sessions": .array([])])
        #expect(WhoElseCall.findAnswer(wrong, depth: 0) == nil)
        #expect(WhoElseCall.findAnswer(.string("No other session works on these."), depth: 0) == nil)
    }

    // MARK: Wording

    @Test func theLineSaysLookingNobodyOneOrHowMany() throws {
        #expect(WhoElseCall(pending: true, answer: nil).line == "Looking for who else works on these files…")
        let full = try #require(WhoElseCall.findAnswer(Self.answer, depth: 0))
        #expect(WhoElseCall(pending: false, answer: full).line == "2 other sessions work on these files")
        var one = full
        one.sessions = [full.sessions[0]]
        #expect(WhoElseCall(pending: false, answer: one).line == "1 other session works on these files")
        one.sessions = []
        #expect(WhoElseCall(pending: false, answer: one).line == "No other session works on these files")
        #expect(WhoElseCall(pending: false, answer: full).unreachedNote == "Not asked: cosmic-gray")
        // Two shown, two more acpmux left out.
        #expect(WhoElseCall(pending: false, answer: full).hiddenCount(shown: 2) == 2)
        #expect(WhoElseCall(pending: false, answer: full).hiddenCount(shown: 1) == 3)
    }

    @Test func aRowSaysWhatItHasInCommonAndWhen() throws {
        let sessions = try #require(WhoElseCall.findAnswer(Self.answer, depth: 0)).sessions
        #expect(sessions[0].whatText == "edited mux.rs, server.rs · read Cargo.toml · +2 more · in this worktree")
        #expect(sessions[0].whereText == "codex · lane/crate-split")
        #expect(sessions[0].agoText == "4m ago")
        #expect(sessions[0].displayName == "crate-split")
        #expect(sessions[1].whatText == "topic: crate, split")
        #expect(sessions[1].whereText == "opencode")
        #expect(sessions[1].agoText == "26h ago")
        #expect(sessions[1].displayName == "big-red/mux-rs")
        var later = sessions[1]
        later.agoMs = 3 * 86_400_000
        #expect(later.agoText == "3d ago")
        later.agoMs = 30_000
        #expect(later.agoText == "now")
        #expect(WhoElseCall.pullLabel("https://github.com/example/cmux/pull/36001") == "#36001")
        #expect(WhoElseCall.pullLabel("https://example.com/review/abc") == "abc")
    }

    // MARK: Real calls

    /// The acpmux updates a live Claude session's MCP `who_else` and a live Codex session's
    /// `sleep 60 && …/acpmux --json who-else src/lib.rs` sent in an end-to-end run while both edited
    /// src/lib.rs (the Mac's `whoElseCalls.fixture.json`, paths renamed).
    static let claudeUpdates = [
        #"{"_meta":{"claude":{"tool":"mcp__acpmux__who_else"}},"kind":"other","sessionUpdate":"tool_call","status":"pending","title":"mcp__acpmux__who_else","toolCallId":"toolu_01HFCBe7BmFwhRWdnaSLcdI0"}"#,
        #"{"_meta":{"claude":{"tool":"mcp__acpmux__who_else"}},"kind":"other","rawInput":{"files":["src/lib.rs"]},"sessionUpdate":"tool_call_update","status":"in_progress","title":"mcp__acpmux__who_else","toolCallId":"toolu_01HFCBe7BmFwhRWdnaSLcdI0"}"#,
        #"{"content":[{"content":{"text":"{\"lines\":[\"greet-codex (codex, lane/greeting): edited src/lib.rs; now\"],\"more\":0,\"query\":{\"branch\":null,\"fileCount\":1,\"files\":[\"src/lib.rs\"],\"topic\":null,\"worktree\":null},\"schema\":\"acpmux.who-else.v1\",\"sessions\":[{\"agoMs\":395,\"branch\":\"lane/greeting\",\"cwd\":\"/home/me/demo/proj/wt-codex\",\"editedInCommon\":1,\"files\":[{\"at\":1793878498634,\"edited\":true,\"path\":\"src/lib.rs\",\"repo\":\"github.com/example/who-else-demo\"}],\"filesInCommon\":1,\"harness\":\"codex\",\"lastActiveAt\":1793878615166,\"live\":true,\"name\":\"greet-codex\",\"pullRequests\":[],\"ref\":\"greet-codex\",\"sameBranch\":false,\"sameWorktree\":false,\"score\":100,\"sessionId\":\"01a1ab67-5314-75d0-9422-b331f723a904\",\"status\":\"running\",\"title\":\"Add Rust farewell function\",\"topicWords\":[]}],\"unreached\":[]}","type":"text"},"type":"content"}],"sessionUpdate":"tool_call_update","status":"completed","toolCallId":"toolu_01HFCBe7BmFwhRWdnaSLcdI0"}"#,
    ]
    static let codexUpdates = [
        #"{"_meta":{"codexAppServer":{"itemType":"commandExecution"}},"kind":"execute","rawInput":{"command":"sleep 60 && /home/me/demo/acpmux --json who-else src/lib.rs","commandLine":"/bin/bash -lc 'sleep 60 && /home/me/demo/acpmux --json who-else src/lib.rs'","cwd":"/home/me/demo/proj/wt-codex"},"sessionUpdate":"tool_call","status":"in_progress","title":"sleep 60 && /home/me/demo/acpmux --json who-else src/lib.rs","toolCallId":"exec-9aaa59bd-180c-4be6-a762-bdb5dfead2f3"}"#,
        #"{"_meta":{"terminal_output_delta":{"data":"{\n  \"lines\": [\n    \"greet-claude (claude, main): edited src/lib.rs; now\"\n  ],\n  \"more\": 0,\n  \"query\": {\n    \"branch\": null,\n    \"fileCount\": 1,\n    \"files\": [\n      \"src/lib.rs\"\n    ],\n    \"topic\": null,\n    \"worktree\": null\n  },\n  \"schema\": \"acpmux.who-else.v1\",\n  \"sessions\": [\n    {\n      \"agoMs\": 288,\n      \"branch\": \"main\",\n      \"cwd\": \"/home/me/demo/proj/repo\",\n      \"editedInCommon\": 1,\n      \"files\": [\n        {\n          \"at\": 1793877467524,\n          \"edited\": true,\n          \"path\": \"src/lib.rs\",\n          \"repo\": \"github.com/example/who-else-demo\"\n        }\n      ],\n      \"filesInCommon\": 1,\n      \"harness\": \"claude\",\n      \"lastActiveAt\": 1793878614856,\n      \"live\": true,\n      \"name\": \"greet-claude\",\n      \"pullRequests\": [],\n      \"ref\": \"greet-claude\",\n      \"sameBranch\": false,\n      \"sameWorktree\": false,\n      \"score\": 100,\n      \"sessionId\": \"01a1ab67-4e14-78f0-bd0f-a184e188adcc\",\n      \"status\": \"running\",\n      \"title\": \"Update Rust greet to hello world\",\n      \"topicWords\": []\n    }\n  ],\n  \"unreached\": []\n}\n","terminal_id":"exec-9aaa59bd-180c-4be6-a762-bdb5dfead2f3"}},"content":[{"content":{"text":"{\n  \"lines\": [\n    \"greet-claude (claude, main): edited src/lib.rs; now\"\n  ],\n  \"more\": 0,\n  \"query\": {\n    \"branch\": null,\n    \"fileCount\": 1,\n    \"files\": [\n      \"src/lib.rs\"\n    ],\n    \"topic\": null,\n    \"worktree\": null\n  },\n  \"schema\": \"acpmux.who-else.v1\",\n  \"sessions\": [\n    {\n      \"agoMs\": 288,\n      \"branch\": \"main\",\n      \"cwd\": \"/home/me/demo/proj/repo\",\n      \"editedInCommon\": 1,\n      \"files\": [\n        {\n          \"at\": 1793877467524,\n          \"edited\": true,\n          \"path\": \"src/lib.rs\",\n          \"repo\": \"github.com/example/who-else-demo\"\n        }\n      ],\n      \"filesInCommon\": 1,\n      \"harness\": \"claude\",\n      \"lastActiveAt\": 1793878614856,\n      \"live\": true,\n      \"name\": \"greet-claude\",\n      \"pullRequests\": [],\n      \"ref\": \"greet-claude\",\n      \"sameBranch\": false,\n      \"sameWorktree\": false,\n      \"score\": 100,\n      \"sessionId\": \"01a1ab67-4e14-78f0-bd0f-a184e188adcc\",\n      \"status\": \"running\",\n      \"title\": \"Update Rust greet to hello world\",\n      \"topicWords\": []\n    }\n  ],\n  \"unreached\": []\n}\n","type":"text"},"type":"content"}],"sessionUpdate":"tool_call_update","toolCallId":"exec-9aaa59bd-180c-4be6-a762-bdb5dfead2f3"}"#,
        #"{"_meta":{"codexAppServer":{"itemType":"commandExecution"}},"content":[{"content":{"text":"{\n  \"lines\": [\n    \"greet-claude (claude, main): edited src/lib.rs; now\"\n  ],\n  \"more\": 0,\n  \"query\": {\n    \"branch\": null,\n    \"fileCount\": 1,\n    \"files\": [\n      \"src/lib.rs\"\n    ],\n    \"topic\": null,\n    \"worktree\": null\n  },\n  \"schema\": \"acpmux.who-else.v1\",\n  \"sessions\": [\n    {\n      \"agoMs\": 288,\n      \"branch\": \"main\",\n      \"cwd\": \"/home/me/demo/proj/repo\",\n      \"editedInCommon\": 1,\n      \"files\": [\n        {\n          \"at\": 1793877467524,\n          \"edited\": true,\n          \"path\": \"src/lib.rs\",\n          \"repo\": \"github.com/example/who-else-demo\"\n        }\n      ],\n      \"filesInCommon\": 1,\n      \"harness\": \"claude\",\n      \"lastActiveAt\": 1793878614856,\n      \"live\": true,\n      \"name\": \"greet-claude\",\n      \"pullRequests\": [],\n      \"ref\": \"greet-claude\",\n      \"sameBranch\": false,\n      \"sameWorktree\": false,\n      \"score\": 100,\n      \"sessionId\": \"01a1ab67-4e14-78f0-bd0f-a184e188adcc\",\n      \"status\": \"running\",\n      \"title\": \"Update Rust greet to hello world\",\n      \"topicWords\": []\n    }\n  ],\n  \"unreached\": []\n}\n","type":"text"},"type":"content"}],"kind":"execute","rawInput":{"command":"sleep 60 && /home/me/demo/acpmux --json who-else src/lib.rs","commandLine":"/bin/bash -lc 'sleep 60 && /home/me/demo/acpmux --json who-else src/lib.rs'","cwd":"/home/me/demo/proj/wt-codex"},"rawOutput":{"duration_ms":59874,"exit_code":0,"status":"completed"},"sessionUpdate":"tool_call_update","status":"completed","title":"sleep 60 && /home/me/demo/acpmux --json who-else src/lib.rs","toolCallId":"exec-9aaa59bd-180c-4be6-a762-bdb5dfead2f3"}"#,
    ]

    static func replayed(_ updates: [String]) throws -> ACPToolCall {
        var call = try JSONDecoder().decode(ACPToolCall.self, from: Data(try #require(updates.first).utf8))
        for update in updates.dropFirst() {
            call.apply(try JSONDecoder().decode(ACPToolCallUpdate.self, from: Data(update.utf8)))
        }
        return call
    }

    @Test func aLiveClaudeMcpCallReadsAsTheCardNamingTheCodexSession() throws {
        let call = try #require(WhoElseCall(try Self.replayed(Self.claudeUpdates)))
        #expect(!call.pending)
        let session = try #require(call.answer?.sessions.first)
        #expect([session.name, session.harness, session.branch] == ["greet-codex", "codex", "lane/greeting"])
        #expect(session.editedInCommon == 1)
    }

    @Test func aLiveCodexShellCallReadsAsTheCardNamingTheClaudeSession() throws {
        let call = try #require(WhoElseCall(try Self.replayed(Self.codexUpdates)))
        #expect(!call.pending)
        let session = try #require(call.answer?.sessions.first)
        #expect([session.name, session.harness, session.branch] == ["greet-claude", "claude", "main"])
        #expect(session.editedInCommon == 1)
    }

    // MARK: The transcript

    @Test func theCallStandsAloneAndDrawsAsTheCard() throws {
        var turn = AgentTurn(id: "t1", prompt: "who else?", promptAt: Date(timeIntervalSince1970: 1_700_000_000))
        let read = ACPToolCall(id: "r1", title: "Read a.rs", kind: .read, status: .completed, locations: [.init(path: "a.rs")])
        var who = Self.call(title: "mcp__acpmux__who_else", output: Self.answer)
        who.id = "w1"
        let read2 = ACPToolCall(id: "r2", title: "Read b.rs", kind: .read, status: .completed, locations: [.init(path: "b.rs")])
        turn.items = [.tool(read), .tool(who), .tool(read2)]
        // Not folded into a read group with its neighbors.
        #expect(turn.rows.map(\.id) == ["c-r1", "c-w1", "c-r2"])
        let rows = ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: [turn], pendingPermission: nil, askOpen: false,
                                                                       permissionBarHidden: false)
        let kinds = rows.flatMap(\.rows).map(\.kind)
        #expect(kinds.contains { if case .whoElse("w1", let call) = $0 { call.answer?.sessions.count == 2 } else { false } })
        #expect(!kinds.contains { if case .tool(let call) = $0 { call.id == "w1" } else { false } })
    }
}
