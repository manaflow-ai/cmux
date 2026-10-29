import CmuxAgentQuestion
@testable import CmuxChief
import Foundation
import Testing

/// The `cmux-question` / `cmux-result` blocks lifted out of the Chief's reply
/// text, alone and through the Claude Code and Codex parsers.
@Suite struct ChiefStructuredBlocksTests {
    static let questionBody = """
    {"submit": "Create", "questions": [{"id": "machine", "header": "Machine", "prompt": "Create a cloud machine?",
     "options": [{"id": "8g", "label": "8 GB", "detail": "4 vCPU · 1 of 3 machines on Pro"}, {"id": "4g", "label": "4 GB"}]}]}
    """
    static let reply = "Here is what I'd set up.\n\n```cmux-question\n\(questionBody)\n```\nPick one."

    private func blocks() -> ChiefStructuredBlocks {
        var blocks = ChiefStructuredBlocks(session: "sess-1")
        blocks.makeID = { "q-fixed" }
        return blocks
    }

    /// Feeds `text` in chunks of `size` characters, then ends the segment.
    private func run(_ text: String, chunk size: Int) -> [ChiefTurnEvent] {
        var filter = blocks()
        var out: [ChiefTurnEvent] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            out += filter.filter(.textDelta(String(rest.prefix(size))))
            rest = rest.dropFirst(size)
        }
        return out + filter.filter(.textSegmentEnd)
    }

    private func text(_ events: [ChiefTurnEvent]) -> String {
        events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
    }

    @Test(arguments: [1, 2, 3, 7, 1000])
    func questionBlockBecomesAQuestionEventAtAnyChunking(size: Int) throws {
        let events = run(Self.reply, chunk: size)
        let questions = events.compactMap { if case .question(let q) = $0 { return q }; return nil }
        #expect(questions.count == 1)
        let question = try #require(questions.first)
        #expect(question.id == "q-fixed")
        #expect(question.source.harness == .chief && question.source.session == "sess-1")
        #expect(question.submitLabel == "Create")
        #expect(question.items.count == 1)
        let item = try #require(question.items.first)
        #expect(item.id == "machine" && item.header == "Machine" && item.prompt == "Create a cloud machine?")
        #expect(item.options.map(\.id) == ["8g", "4g"])
        #expect(item.options.first?.detail == "4 vCPU · 1 of 3 machines on Pro")
        #expect(item.allowsOther == false && item.multiSelect == false)
        // The fence and its JSON never stream as text; the words around it do, in order.
        let shown = text(events)
        #expect(!shown.contains("```") && !shown.contains("cmux-question") && !shown.contains("\"options\""))
        let questionIndex = try #require(events.firstIndex { if case .question = $0 { return true }; return false })
        #expect(text(Array(events[..<questionIndex])) == "Here is what I'd set up.\n\n")
        #expect(text(Array(events[questionIndex...])) == "Pick one.")
        #expect(events.last == .textSegmentEnd)
    }

    @Test func resultBlockBecomesAResultCard() {
        let body = #"{"title": "Codex is working on brave-otter", "subtitle": "fix login · ws_4f2c", "machine": "brave-otter", "workspace": "ws_4f2c", "status": "working"}"#
        let events = run("Started.\n```cmux-result\n\(body)\n```\n", chunk: 5)
        #expect(events.contains(.result(ChiefResultCard(title: "Codex is working on brave-otter", subtitle: "fix login · ws_4f2c",
                                                        machine: "brave-otter", workspace: "ws_4f2c", status: .working))))
        #expect(text(events) == "Started.\n")
    }

    @Test func invalidOrIncompleteBlocksFallBackToText() {
        // Bad JSON: the block's text shows as written.
        let bad = "```cmux-result\n{\"title\": \"x\"}\n```\n"
        #expect(text(run(bad, chunk: 4)) == "```cmux-result\n{\"title\": \"x\"}\n```")
        // The reply ends inside a block: its text shows.
        #expect(text(run("Oops ```cmux-question\n{\"prompt\": ", chunk: 3)) == "Oops ```cmux-question\n{\"prompt\": ")
        // The reply ends on the closing fence with no newline after it: still a block.
        let events = run("```cmux-question\n\(Self.questionBody)\n```", chunk: 6)
        #expect(events.contains { if case .question = $0 { return true }; return false })
        #expect(text(events).isEmpty)
    }

    @Test func otherCodeAndBackticksPassThrough() {
        let reply = "Run `cmux vm ls` first.\n```sh\ncmux vm ls --json\n```\nAnd ```cmux-other\nx\n``` too``"
        let events = run(reply, chunk: 2)
        #expect(text(events) == reply)
        #expect(!events.contains { if case .question = $0 { return true }; if case .result = $0 { return true }; return false })
    }

    @Test func heldTextFlushesBeforeATool() {
        var filter = blocks()
        // A trailing backtick may open a fence: held until the next event.
        #expect(filter.filter(.textDelta("Checking `")) == [.textDelta("Checking ")])
        #expect(filter.filter(.toolStarted(id: "t", title: "ls", detail: nil))
            == [.textDelta("`"), .toolStarted(id: "t", title: "ls", detail: nil)])
    }

    @Test func questionShapeLimits() throws {
        let single = try ChiefJSON(parsing: Data(#"{"prompt": "Size?", "options": [{"label": "8 GB"}, {"label": "4 GB"}]}"#.utf8))
        let question = try #require(ChiefStructuredBlocks.question(single, id: "q", session: "s"))
        #expect(question.items.first?.id == "q0" && question.items.first?.options.map(\.id) == ["o0", "o1"])
        #expect(question.submitLabel == nil)
        let noOptions = try ChiefJSON(parsing: Data(#"{"prompt": "Size?", "options": []}"#.utf8))
        #expect(ChiefStructuredBlocks.question(noOptions, id: "q", session: "s") == nil)
        let duplicate = try ChiefJSON(parsing: Data(#"{"questions": [{"id": "a", "prompt": "1", "options": [{"label": "x"}]}, {"id": "a", "prompt": "2", "options": [{"label": "y"}]}]}"#.utf8))
        #expect(ChiefStructuredBlocks.question(duplicate, id: "q", session: "s") == nil)
    }

    // MARK: Through the parsers

    @Test func claudeParserLiftsTheBlockFromTextDeltas() throws {
        var parser = ClaudeStreamParser(sessionID: "claude-sess")
        parser.blocks.makeID = { "q-claude" }
        parser.beginTurn(echo: "u1")
        func line(_ object: ChiefJSON) -> [ClaudeStreamOutput] { parser.consume(object) }
        var outputs: [ClaudeStreamOutput] = []
        outputs += line(["type": "user", "isReplay": true, "uuid": "u1", "message": ["role": "user", "content": []]])
        outputs += line(["type": "stream_event", "event": ["type": "message_start"]])
        outputs += line(["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "text"]]])
        var rest = Substring(Self.reply)
        while !rest.isEmpty {
            let piece = String(rest.prefix(9))
            rest = rest.dropFirst(9)
            outputs += line(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
                                                               "delta": ["type": "text_delta", "text": .string(piece)]]])
        }
        outputs += line(["type": "stream_event", "event": ["type": "content_block_stop", "index": 0]])
        let events = outputs.compactMap { if case .event(let e) = $0 { return e }; return nil }
        let question = try #require(events.compactMap { if case .question(let q) = $0 { return q }; return nil }.first)
        #expect(question.id == "q-claude" && question.source.session == "claude-sess")
        #expect(text(events) == "Here is what I'd set up.\n\nPick one.")
        #expect(events.last == .textSegmentEnd)
    }

    @Test func codexParserLiftsTheBlockFromAWholeMessage() throws {
        var parser = CodexAppServerParser(threadID: "thread-1")
        parser.blocks.makeID = { "q-codex" }
        parser.beginTurn()
        let outputs = parser.consume(["method": "item/completed",
                                      "params": ["threadId": "thread-1", "turnId": "turn-1",
                                                 "item": ["type": "agentMessage", "id": "m1", "text": .string(Self.reply)]]])
        let events = outputs.compactMap { if case .event(let e) = $0 { return e }; return nil }
        let question = try #require(events.compactMap { if case .question(let q) = $0 { return q }; return nil }.first)
        #expect(question.source.session == "thread-1")
        #expect(text(events) == "Here is what I'd set up.\n\nPick one.")
    }

    /// The prompt's example blocks are valid blocks (a model copying them gets cards).
    @Test func promptExamplesParse() {
        let events = run(ChiefSystemPrompt.cloud, chunk: 64)
        #expect(events.filter { if case .question = $0 { return true }; return false }.count == 1)
        #expect(events.filter { if case .result = $0 { return true }; return false }.count == 1)
        for rule in ["cmux vm new --detach --name", "cmux vm wait <machine> --wake", "limits.memoryOptionsMb",
                     "cmux vm workspace open <machine> <ws>", "\"status\": \"working\""] {
            #expect(ChiefSystemPrompt.cloud.contains(rule), "missing \(rule)")
        }
    }

    // MARK: Provisioning commands

    @Test func provisioningCommandsAreRecognized() {
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cmux vm new --detach --name api --size 8g --json") == .create)
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cmux cloud wait brave-otter --wake") == .wait)
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cd /tmp && cmux vm wait brave-otter") == .wait)
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cmux vm route --provision --json") == .create)
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cmux vm route --json") == nil)
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cmux vm new --help") == nil)
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cmux vm ls --json") == nil)
        #expect(ChiefCloudProvisioning.phase(ofCommand: "cmux vm terminal wait m term --pattern x") == nil)
        #expect(ChiefCloudProvisioning.machine(inOutput: "{\n  \"id\" : \"brave-otter\",\n  \"provider\" : \"x\"") == "brave-otter")
        #expect(ChiefCloudProvisioning.machine(inOutput: "brave-otter is ready\nnext: …") == "brave-otter")
        #expect(ChiefCloudProvisioning.machine(inCommand: "cmux vm wait brave-otter --wake") == "brave-otter")
    }
}
