import CmuxConversation
@testable import CmuxConversationUI
import XCTest

@MainActor
final class ConversationModelTests: XCTestCase {
    func testChangingHostScopeClearsSelectionDraftAndSessions() {
        let model = ConversationModel(scopeID: "host-a")
        model.selectSession(id: ConversationID(rawValue: "session-a"))
        model.updateDraft("keep this draft only on host A")

        model.replaceClient(nil, scopeID: "host-b")

        XCTAssertNil(model.selectedSessionID)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testDisconnectedCreationReportsReconnect() {
        let model = ConversationModel(scopeID: "host-a")
        model.createSession()
        XCTAssertEqual(model.errorMessage, "Reconnect to create a task.")
    }

    func testProviderNamesAndBlockingRequestClassification() {
        XCTAssertEqual(ConversationProvider.codex.displayName, "Codex")
        XCTAssertEqual(ConversationProvider.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(ConversationProvider.openCode.displayName, "OpenCode")
        let request = ConversationRequest(id: "approval", generation: "g1", kind: "question_async")
        XCTAssertFalse(request.isBlocking)
    }


    func testCompactItemUpdatesAppendTextAndToolOutput() {
        let model = ConversationModel(scopeID: "host-a")
        let sessionID = ConversationID(rawValue: "session-a")
        model.selectSession(id: sessionID)

        let textID = ConversationItemID(rawValue: "message-1")
        model.apply(event: ConversationEvent(
            sessionID: sessionID,
            sequence: 1,
            generation: "g1",
            kind: .item,
            item: ConversationItem(id: textID, sequence: 1, kind: .message, role: "assistant", text: "hello")
        ))
        model.apply(event: ConversationEvent(
            sessionID: sessionID,
            sequence: 2,
            generation: "g1",
            kind: .item,
            item: ConversationItem(id: textID, sequence: 2, kind: .message, text: " world"),
            itemUpdate: .appendText
        ))

        let toolID = ConversationItemID(rawValue: "tool-1")
        model.apply(event: ConversationEvent(
            sessionID: sessionID,
            sequence: 3,
            generation: "g1",
            kind: .item,
            item: ConversationItem(
                id: toolID,
                sequence: 3,
                kind: .tool,
                tool: ConversationTool(toolID: "shell", name: "shell", output: .string("one"), status: .running)
            )
        ))
        model.apply(event: ConversationEvent(
            sessionID: sessionID,
            sequence: 4,
            generation: "g1",
            kind: .item,
            item: ConversationItem(
                id: toolID,
                sequence: 4,
                kind: .tool,
                tool: ConversationTool(toolID: "shell", name: "shell", output: .string(" two"), status: .success)
            ),
            itemUpdate: .appendToolOutput
        ))

        XCTAssertEqual(model.items.first(where: { $0.id == textID })?.text, "hello world")
        XCTAssertEqual(model.items.first(where: { $0.id == toolID })?.tool?.output, .string("one two"))
    }

    func testLateCompletionForPriorTurnDoesNotStopCurrentTurn() {
        let model = ConversationModel(scopeID: "host-a")
        let sessionID = ConversationID(rawValue: "session-a")
        model.selectSession(id: sessionID)
        model.apply(event: ConversationEvent(sessionID: sessionID, sequence: 1, generation: "g1", kind: .run, turnID: "turn-new", state: "running"))
        model.apply(event: ConversationEvent(sessionID: sessionID, sequence: 2, generation: "g1", kind: .turn, turnID: "turn-old", state: "completed"))

        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.activeTurnID, ConversationTurnID(rawValue: "turn-new"))
    }

    func testJSONDescriptionPreservesStructuredToolPayload() {
        let value: ConversationJSONValue = .object([
            "command": .string("pwd"),
            "timeout": .number("30"),
        ])
        XCTAssertTrue(value.prettyDescription.contains("\"command\": pwd"))
        XCTAssertTrue(value.prettyDescription.contains("\"timeout\": 30"))
    }
}
