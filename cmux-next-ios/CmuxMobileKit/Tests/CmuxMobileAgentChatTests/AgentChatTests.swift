import CmuxAgentQuestion
@testable import CmuxMobileAgentChat
import CmuxMobileDiff
import CmuxMobileMarkdown
import Foundation
import Testing

@Suite struct MarkdownDocumentTests {
    @Test func splitsBlocks() {
        let doc = MarkdownDocument(parsing: """
        ## Title

        Para with `code` and $x^2$.

        | A | B |
        | :-- | --: |
        | 1 | 2 |

        ```swift
        let a = 1
        ```

        - [x] done
        - todo

        $$
        E = mc^2
        $$
        """)
        let kinds = doc.blocks.map(\.kind)
        #expect(kinds.count == 6)
        if case .heading(2, "Title") = kinds[0] {} else { Issue.record("heading") }
        if case .table(let table) = kinds[2] {
            #expect(table.alignments == [.leading, .trailing])
            #expect(table.rows == [["1", "2"]])
        } else { Issue.record("table") }
        if case .code("swift", "let a = 1", true) = kinds[3] {} else { Issue.record("code") }
        if case .list(let list) = kinds[4] { #expect(list.items.map(\.checked) == [true, nil]) } else { Issue.record("list") }
        if case .math("E = mc^2") = kinds[5] {} else { Issue.record("math") }
        #expect(doc.needsWebRenderer)
    }

    @Test func pricesAreNotMath() {
        #expect(!MarkdownDocument(parsing: "It costs $5 and $6 today").needsWebRenderer)
    }

    @Test func unclosedDisplayMathStaysSource() {
        let doc = MarkdownDocument(parsing: "$$\nT = \\frac{a")
        if case .code("tex", _, false) = doc.blocks.first?.kind {} else { Issue.record("expected tex source") }
    }
}

@Suite struct DiffModelTests {
    @Test func lineAndWordDiff() {
        let file = DiffFile(path: "a/User.swift", oldText: "a\nlet name = 1\nc\n", newText: "a\nlet title = 1\nc\nd\n")
        #expect(file.additions == 2)
        #expect(file.deletions == 1)
        let removed = file.lines.first { $0.kind == .removed }
        #expect(removed?.changedRanges == [4..<8])
        #expect(file.hunks().count == 1)
    }

    @Test func parsesUnifiedDiff() {
        let files = UnifiedDiffParser().parse("""
        diff --git a/x.txt b/x.txt
        --- a/x.txt
        +++ b/x.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        """)
        #expect(files.count == 1)
        #expect(files[0].additions == 1 && files[0].deletions == 1)
        #expect(files[0].lines.first?.newNumber == 1)
    }
}

@Suite @MainActor struct AgentChatStoreTests {
    @Test func decodesToolCallUpdate() throws {
        let json = #"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Edit a.swift","kind":"edit","status":"completed","content":[{"type":"diff","path":"a.swift","oldText":"x","newText":"y"}]}"#
        let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
        guard case .toolCall(let call) = update else { Issue.record("kind"); return }
        #expect(call.diffs.first?.path == "a.swift")
    }

    /// A phone's Allow is refused ("Approve this on your Mac"); the decline
    /// that follows resolves the ask, so the refusal must not stay on screen.
    @Test func answeringAgainClearsTheLastRefusal() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 4000
        let store = AgentChatStore(source: mock)
        while store.turns.isEmpty { await Task.yield() }
        store.send(prompt: "go")
        while store.pendingPermission == nil { await Task.yield() }
        let permission = try #require(store.pendingPermission)
        store.clientError = "Approve this on your Mac. A phone can only decline."
        store.respond(to: permission.request, option: permission.request.options.last)
        #expect(store.clientError == nil)
    }

    /// A tab the Mac reports as waiting opens on its card, and the replayed
    /// history arrives as one change (no past turn ever shows "Working").
    @Test func waitingMockSessionsOpenOnTheirCard() async throws {
        func session(_ harness: String) -> MockAgentSession {
            let mock = MockAgentSession(
                summary: AgentSessionSummary(id: "t-\(harness)", name: "Resolve merge conflicts", harness: harness, agentName: harness,
                                             cwd: "~", workspaceTitle: "w", macName: "m", status: .waiting),
                sleep: { _ in await Task.yield() }
            )
            mock.chunkSize = 4000
            return mock
        }
        let codex = AgentChatStore(source: session("codex"))
        while codex.turns.isEmpty { await Task.yield() }
        // Everything replayed in one step: history done, the waiting turn up, its ask pending.
        #expect(codex.turns.dropLast().allSatisfy { $0.status == .completed })
        #expect(codex.turns.last?.prompt == "Resolve merge conflicts")
        let permission = try #require(codex.pendingPermission)
        codex.respond(to: permission.request, option: permission.request.options.first)
        while codex.isRunning { await Task.yield() }
        #expect(codex.turns.last?.status == .completed)

        let claude = AgentChatStore(source: session("claude"))
        while claude.turns.isEmpty { await Task.yield() }
        let question = try #require(claude.pendingQuestion)
        claude.answer(question, with: AgentQuestionAnswer(selections: ["default": .init(optionIDs: ["webrtc"])]))
        while claude.isRunning { await Task.yield() }
        #expect(claude.turns.last?.status == .completed)
    }

    @Test func mockStreamsFullTurn() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 4000
        let store = AgentChatStore(source: mock)
        while store.turns.isEmpty { await Task.yield() }
        store.send(prompt: "go")
        while store.pendingPermission == nil { await Task.yield() }
        let permission = try #require(store.pendingPermission)
        store.respond(to: permission.request, option: permission.request.options.first)
        while store.pendingQuestion == nil { await Task.yield() }
        let question = try #require(store.pendingQuestion)
        store.answer(question, with: AgentQuestionAnswer(selections: [
            "default": .init(optionIDs: ["wireguard"]), "surfaces": .init(optionIDs: ["connection"]),
        ]))
        while store.isRunning { await Task.yield() }
        let turn = try #require(store.turns.last)
        #expect(turn.status == .completed)
        #expect(turn.changeSet?.files.count == 3)
        #expect(turn.rows.contains { if case .toolGroup = $0 { return true }; return false })
        #expect(turn.answerMarkdown.contains("WireGuard"))
    }

    @Test func groupSummaryWording() {
        let calls = [
            ACPToolCall(id: "1", title: "", kind: .read, status: .completed, locations: [.init(path: "a")]),
            ACPToolCall(id: "2", title: "", kind: .read, status: .completed, locations: [.init(path: "b")]),
            ACPToolCall(id: "3", title: "", kind: .execute, status: .completed),
        ]
        #expect(ToolWording().summary(calls) == "Read 2 files, ran a command")
    }
}
