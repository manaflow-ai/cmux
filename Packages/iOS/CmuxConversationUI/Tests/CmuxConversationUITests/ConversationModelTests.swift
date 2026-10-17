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

    func testJSONDescriptionPreservesStructuredToolPayload() {
        let value: ConversationJSONValue = .object([
            "command": .string("pwd"),
            "timeout": .number("30"),
        ])
        XCTAssertTrue(value.prettyDescription.contains("\"command\": pwd"))
        XCTAssertTrue(value.prettyDescription.contains("\"timeout\": 30"))
    }
}
