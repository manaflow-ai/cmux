@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

@Suite struct CodexAppServerParserTests {
    private func feed(_ parser: inout CodexAppServerParser, _ lines: [String]) -> [CodexOutput] {
        lines.flatMap { parser.consume(Data($0.utf8)) }
    }

    private func json(_ text: String) throws -> ChiefJSON {
        try ChiefJSON(parsing: Data(text.utf8))
    }

    @Test func turnStreamsACommandThenAReply() {
        var parser = CodexAppServerParser(threadID: "thread-1")
        parser.beginTurn()
        let outputs = feed(&parser, ChiefBrainFixtures.codexTurn)
        #expect(outputs == [
            .response(id: 3, result: ["turn": ["id": "turn-1", "status": "inProgress", "items": []]], error: nil),
            .event(.toolStarted(id: "call-1", title: "cmux list-workspaces", detail: "cmux list-workspaces")),
            .approval(requestID: 0, kind: .command, command: "/bin/zsh -lc 'cmux list-workspaces'",
                      prompt: "Run `cmux list-workspaces`?"),
            .event(.toolFinished(id: "call-1", ok: true, preview: "ws-1\nws-2")),
            .event(.textDelta("Two ")),
            .event(.textDelta("workspaces.")),
            .event(.textSegmentEnd),
            .event(.finished),
        ])
        #expect(parser.turnActive == false)
    }

    @Test func failedCommandAndFailedTurn() {
        var parser = CodexAppServerParser(threadID: "t")
        parser.beginTurn()
        let outputs = feed(&parser, [
            #"{"method":"item/started","params":{"threadId":"t","turnId":"u","item":{"type":"commandExecution","id":"c","command":"make","status":"inProgress"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"type":"commandExecution","id":"c","command":"make","status":"completed","exitCode":2,"aggregatedOutput":"error: x"}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"failed","error":{"message":"Quota exceeded"}}}}"#,
        ])
        #expect(outputs == [
            .event(.toolStarted(id: "c", title: "make", detail: "make")),
            .event(.toolFinished(id: "c", ok: false, preview: "error: x")),
            .event(.failed("Quota exceeded")),
        ])
    }

    /// An approval without `command` takes the command of its started item.
    @Test func approvalFallsBackToTheItemCommand() {
        var parser = CodexAppServerParser(threadID: "t")
        parser.beginTurn()
        let outputs = feed(&parser, [
            #"{"method":"item/started","params":{"threadId":"t","turnId":"u","item":{"type":"commandExecution","id":"c","command":"/bin/zsh -lc 'cmux tree'","status":"inProgress"}}}"#,
            #"{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"t","turnId":"u","itemId":"c","startedAtMs":1}}"#,
        ])
        #expect(outputs.last == .approval(requestID: 0, kind: .command, command: "/bin/zsh -lc 'cmux tree'",
                                          prompt: "Run `cmux tree`?"))
    }

    @Test func unstreamedMessageArrivesWhole() {
        var parser = CodexAppServerParser(threadID: "t")
        parser.beginTurn()
        let outputs = feed(&parser, [
            #"{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"type":"agentMessage","id":"m","text":"hi"}}}"#,
        ])
        #expect(outputs == [.event(.textDelta("hi")), .event(.textSegmentEnd)])
    }

    @Test func stoppedTurnAndOtherThreadsAreDropped() {
        var parser = CodexAppServerParser(threadID: "t")
        parser.beginTurn()
        parser.setTurnID("old")
        parser.abandonTurn()
        parser.beginTurn()
        let outputs = feed(&parser, [
            #"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"old","itemId":"m","delta":"late"}}"#,
            #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"old","status":"interrupted"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"other","turnId":"new","itemId":"m","delta":"elsewhere"}}"#,
            #"{"method":"turn/started","params":{"threadId":"t","turn":{"id":"new"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"new","itemId":"m2","delta":"fresh"}}"#,
            #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"new","status":"interrupted"}}}"#,
        ])
        #expect(outputs == [.event(.textDelta("fresh")), .event(.textSegmentEnd), .event(.finished)])
    }

    @Test func serverRequestsAndTheirAnswers() throws {
        var parser = CodexAppServerParser(threadID: "t")
        let outputs = feed(&parser, [
            #"{"id":"a","method":"item/fileChange/requestApproval","params":{"threadId":"t","turnId":"u","itemId":"f","startedAtMs":1}}"#,
            #"{"id":5,"method":"execCommandApproval","params":{"callId":"c","conversationId":"t","cwd":"/","parsedCmd":[],"command":["git","status"]}}"#,
            #"{"id":6,"method":"item/tool/requestUserInput","params":{}}"#,
            #"{"id":2,"error":{"code":-32000,"message":"thread not found"}}"#,
        ])
        #expect(outputs == [
            .approval(requestID: "a", kind: .fileChange, command: nil, prompt: "Allow these file changes?"),
            .approval(requestID: 5, kind: .legacyCommand, command: "git status", prompt: "Run `git status`?"),
            .unsupportedRequest(requestID: 6, method: "item/tool/requestUserInput"),
            .response(id: 2, result: nil, error: "thread not found"),
        ])
        #expect(CodexAppServerParser.approvalResponse(requestID: "a", kind: .fileChange, allow: true)
            == (try json(#"{"id":"a","result":{"decision":"accept"}}"#)))
        #expect(CodexAppServerParser.approvalResponse(requestID: 4, kind: .command, allow: false)
            == (try json(#"{"id":4,"result":{"decision":"decline"}}"#)))
        #expect(CodexAppServerParser.approvalResponse(requestID: 5, kind: .legacyCommand, allow: false)
            == (try json(#"{"id":5,"result":{"decision":{"denied":{"rejection":"The user rejected this action."}}}}"#)))
        #expect(CodexAppServerParser.unsupportedResponse(requestID: 6, method: "x")["error"]?["code"] == .number(-32601))
    }

    @Test func requestParamsCarryModelEffortAndInstructions() {
        let request = ChiefTurnRequest(conversation: ConversationID("conv_1"), resumeSession: nil, userText: "hi",
                                       attachmentPaths: [URL(fileURLWithPath: "/tmp/a.png")], replyContext: nil,
                                       systemPrompt: "Be Chief.", workingDirectory: URL(fileURLWithPath: "/tmp"),
                                       environment: [:])
        let configuration = CodexAppServerBrain.Configuration(model: "gpt-6.1-sol", effort: "high")
        let thread = CodexAppServerBrain.threadParams(configuration, request: request, resume: "th")
        #expect(thread["developerInstructions"] == "Be Chief.")
        #expect(thread["approvalPolicy"] == "untrusted")
        #expect(thread["threadId"] == "th")
        let turn = CodexAppServerBrain.turnParams(configuration, request: request, thread: "th")
        #expect(turn["effort"] == "high")
        #expect(turn["model"] == "gpt-6.1-sol")
        #expect(turn["input"]?.array?.count == 2)
        #expect(turn["input"]?.array?.last?["type"] == "localImage")
    }

    @Test func dangerousPermissionModeIsExplicitAndOptIn() {
        let request = ChiefTurnRequest(conversation: ConversationID("conv_1"),
                                       resumeSession: nil, userText: "hi", attachmentPaths: [],
                                       replyContext: nil, systemPrompt: "", workingDirectory: URL(fileURLWithPath: "/tmp"),
                                       environment: [:])
        let safe = CodexAppServerBrain.threadParams(.init(model: "m"), request: request, resume: nil)
        #expect(safe["approvalPolicy"] == "untrusted")
        #expect(safe["sandbox"] == "workspace-write")
        let dangerous = CodexAppServerBrain.threadParams(
            .init(model: "m", dangerouslySkipPermissions: true), request: request, resume: nil)
        #expect(dangerous["approvalPolicy"] == "never")
        #expect(dangerous["sandbox"] == "danger-full-access")
    }
}
