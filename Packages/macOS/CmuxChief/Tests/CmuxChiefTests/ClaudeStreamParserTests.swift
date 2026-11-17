@testable import CmuxChief
import Foundation
import Testing

@Suite struct ClaudeStreamParserTests {
    private func feed(_ parser: inout ClaudeStreamParser, _ lines: [String]) -> [ClaudeStreamOutput] {
        lines.flatMap { parser.consume(Data($0.utf8)) }
    }

    private func json(_ text: String) throws -> ChiefJSON {
        try ChiefJSON(parsing: Data(text.utf8))
    }

    @Test func recordedTextTurnStreamsOneSegment() {
        var parser = ClaudeStreamParser()
        parser.beginTurn(echo: ChiefBrainFixtures.claudePromptUUID)
        let outputs = feed(&parser, ChiefBrainFixtures.claudeTextTurn)
        #expect(outputs == [
            .event(.session(ChiefBrainFixtures.claudeSession)),
            .event(.textDelta("hi")),
            .event(.textSegmentEnd),
            .event(.finished),
        ])
        #expect(parser.turnActive == false)
        #expect(parser.sessionID == ChiefBrainFixtures.claudeSession)
    }

    @Test func recordedToolTurnAsksPermissionAndReportsTheTool() throws {
        var parser = ClaudeStreamParser(sessionID: ChiefBrainFixtures.toolSession)
        parser.beginTurn(echo: ChiefBrainFixtures.toolPromptUUID)
        let outputs = feed(&parser, ChiefBrainFixtures.claudeToolTurn)
        let input = try json(#"{"command":"mkdir -p /tmp/chief-probe2/made","description":"Make dir"}"#)
        #expect(outputs == [
            .event(.toolStarted(id: "toolu_01X8nuDECCbcBCpyE7qgG1kw", title: "Make dir", detail: "mkdir -p /tmp/chief-probe2/made")),
            .permission(requestID: "4efd7959-8a24-4a8a-877d-fbf0304f7e7e", tool: "Bash", input: input),
            .event(.toolFinished(id: "toolu_01X8nuDECCbcBCpyE7qgG1kw", ok: true, preview: "(Bash completed with no output)")),
            .event(.textDelta("done")),
            .event(.textSegmentEnd),
            .event(.finished),
        ])
    }

    /// A stopped turn's late output and result must not end the next turn.
    @Test func abandonedTurnOutputIsDroppedUntilTheNextPromptIsEchoed() {
        var parser = ClaudeStreamParser(sessionID: "s")
        parser.beginTurn(echo: "a")
        _ = feed(&parser, [
            #"{"type":"user","uuid":"a","isReplay":true,"message":{"content":[]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"old"}}}"#,
        ])
        parser.abandonTurn()
        parser.beginTurn(echo: "b")
        let outputs = feed(&parser, [
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" late"}}}"#,
            #"{"type":"result","subtype":"error_during_execution","is_error":false,"result":null,"num_turns":1,"duration_api_ms":10}"#,
            #"{"type":"user","uuid":"b","isReplay":true,"message":{"content":[]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"new"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"new","num_turns":1,"duration_api_ms":10}"#,
        ])
        #expect(outputs == [.event(.textDelta("new")), .event(.textSegmentEnd), .event(.finished)])
    }

    /// The stopped turn's result may come after the next prompt's echo but
    /// before its output.
    @Test func abandonedResultAfterEchoIsDropped() {
        var parser = ClaudeStreamParser(sessionID: "s")
        parser.beginTurn(echo: "a")
        parser.abandonTurn()
        parser.beginTurn(echo: "b")
        let outputs = feed(&parser, [
            #"{"type":"user","uuid":"b","isReplay":true,"message":{"content":[]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"","num_turns":1,"duration_api_ms":10}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"ok","num_turns":1,"duration_api_ms":10}"#,
        ])
        #expect(outputs == [.event(.textDelta("ok")), .event(.textSegmentEnd), .event(.finished)])
    }

    @Test func resumedProcessStartupResultIsNotTheEndOfTheTurn() {
        var parser = ClaudeStreamParser(sessionID: "s")
        parser.beginTurn(echo: "a")
        let outputs = feed(&parser, [
            #"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"duration_api_ms":0,"result":""}"#,
        ])
        #expect(outputs.isEmpty)
        #expect(parser.turnActive)
    }

    @Test func errorResultFailsTheTurnWithItsMessage() {
        var parser = ClaudeStreamParser(sessionID: "s")
        parser.beginTurn(echo: "a")
        let outputs = feed(&parser, [
            #"{"type":"result","subtype":"success","is_error":true,"num_turns":1,"duration_api_ms":5,"result":"Usage limit reached"}"#,
        ])
        #expect(outputs == [.event(.failed("Usage limit reached"))])
    }

    @Test func subagentLinesAreSkipped() {
        var parser = ClaudeStreamParser(sessionID: "s")
        parser.beginTurn(echo: "a")
        let outputs = feed(&parser, [
            #"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#,
        ])
        #expect(outputs.isEmpty)
    }

    @Test func otherControlRequestsAreRefused() {
        var parser = ClaudeStreamParser(sessionID: "s")
        let outputs = feed(&parser, [#"{"type":"control_request","request_id":"r1","request":{"subtype":"mcp_message"}}"#])
        #expect(outputs == [.unsupportedControl(requestID: "r1", subtype: "mcp_message")])
    }

    @Test func stdinLinesMatchTheShapesClaudeCodeAccepts() throws {
        let input = try json(#"{"command":"ls"}"#)
        #expect(ClaudeStreamParser.permissionResponse(requestID: "r", allow: true, input: input) == (try json(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"r","response":{"behavior":"allow","updatedInput":{"command":"ls"}}}}"#
        )))
        #expect(ClaudeStreamParser.permissionResponse(requestID: "r", allow: false, input: input) == (try json(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"r","response":{"behavior":"deny","message":"The user rejected this action."}}}"#
        )))
        #expect(ClaudeStreamParser.interruptRequest(id: "int-1") == (try json(
            #"{"type":"control_request","request_id":"int-1","request":{"subtype":"interrupt"}}"#
        )))
        let line = ClaudeStreamParser.userMessage(uuid: "u", content: [["type": "text", "text": "hi"]]).line
        #expect(line.last == 0x0A)
        #expect(try ChiefJSON(parsing: line.dropLast()) == (try json(
            #"{"type":"user","uuid":"u","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        )))
    }

    @Test func launchArgumentsCarryTheStreamJSONProtocol() {
        let configuration = ClaudeCodeBrain.Configuration(model: "claude-opus-5-5", effort: "high")
        let fresh = ClaudeCodeBrain.arguments(configuration, session: .new("id-1"), systemPrompt: "Be Chief.")
        #expect(fresh.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                    "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
                                    "--model", "claude-opus-5-5", "--effort", "high", "--session-id", "id-1",
                                    "--append-system-prompt", "Be Chief."]))
        #expect(fresh.contains("--tools"))
        let resumed = ClaudeCodeBrain.arguments(.init(model: "m", extraArguments: []), session: .resume("id-2"), systemPrompt: "")
        #expect(resumed.suffix(2) == ["--resume", "id-2"])
        #expect(!resumed.contains("--effort"))
    }

    @Test func dangerousPermissionModeReplacesTheDefaultPermissionMode() {
        let arguments = ClaudeCodeBrain.arguments(
            .init(model: "m", dangerouslySkipPermissions: true), session: .new("id"), systemPrompt: "")
        #expect(arguments.contains("bypassPermissions"))
        #expect(!arguments.contains("default"))
    }
}

@Suite struct ChiefBrainSupportTests {
    @Test func framerSplitsChunksAndKeepsPartialLines() {
        var framer = ChiefLineFramer()
        #expect(framer.append(Data("{\"a\":1}\r\n\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(framer.append(Data(":2}\n{\"c\"".utf8)) == [Data("{\"b\":2}".utf8)])
        #expect(framer.finish() == Data("{\"c\"".utf8))
        #expect(framer.finish() == nil)
    }

    @Test func jsonKeepsIntegersAndBooleansApart() throws {
        let value = try ChiefJSON(parsing: Data(#"{"id":7,"ok":true,"n":1.5,"s":"a/b","x":null}"#.utf8))
        #expect(value["id"] == .number(7))
        #expect(value["ok"] == .bool(true))
        #expect(value["x"]?.isNull == true)
        let text = String(decoding: value.line, as: UTF8.self)
        #expect(text.contains(#""id":7"#))
        #expect(text.contains(#""s":"a/b""#))
    }

    @Test func claudeToolsPolicyAndTitles() throws {
        #expect(ChiefToolPolicy.autoAllowsClaudeTool("Read", input: ["file_path": "/tmp/chief-notes.txt"]))
        #expect(!ChiefToolPolicy.autoAllowsClaudeTool("Read", input: [:]))
        #expect(ChiefToolPolicy.autoAllowsClaudeTool("WebSearch", input: [:]))
        #expect(!ChiefToolPolicy.autoAllowsClaudeTool("Write", input: ["file_path": "/tmp/x"]))
        #expect(ChiefToolPolicy.autoAllowsClaudeTool("Bash", input: ["command": "cmux tree"]))
        #expect(!ChiefToolPolicy.autoAllowsClaudeTool("Bash", input: ["command": "make"]))
        #expect(ChiefToolPolicy.claudeTitle("Bash", input: ["command": "make all"]) == "make all")
        #expect(ChiefToolPolicy.claudeTitle("Read", input: ["file_path": "/a/b.swift"]) == "Read /a/b.swift")
        #expect(ChiefToolPolicy.claudeTitle("mcp__optchat__zoom", input: [:]) == "zoom")
        let long = String(repeating: "x", count: 200)
        #expect(ChiefToolPolicy.claudeTitle("Bash", input: ["command": .string(long)]).count == 80)
    }

    @Test func catalogDefaultsAndFactory() {
        #expect(ChiefHarness.claude.defaultModel == "claude-opus-5-5")
        #expect(ChiefHarness.codex.defaultModel == "gpt-6.1-sol")
        #expect(ChiefHarness.claude.models.map(\.id).contains("claude-fable-5-1"))
        #expect(ChiefHarness.claude.efforts(for: "claude-opus-5-5").map(\.id) == ["low", "medium", "high", "xhigh", "max"])
        #expect(ChiefHarness(lenient: "codex").makeBrain(model: nil, effort: nil) is CodexAppServerBrain)
        #expect(ChiefHarness(lenient: "claude").makeBrain(model: "", effort: "default") is ClaudeCodeBrain)
        #expect(ChiefHarness(lenient: "unknown").makeBrain(model: nil, effort: nil) is ClaudeCodeBrain)
    }
}
