import Foundation
import Testing
@testable import CmuxNextDaemon

struct ConversationQuestionDecisionRequestTests {
    private func keys(_ request: ConversationQuestionDecisionRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }

    @Test func theDisplayedQuestionIsSentAsTheQuestionField() throws {
        let shown = JSONValue.object(["session": .string("local/s1")])
        let sent = try keys(.init(conversation: "c", messageID: "m", partIndex: 0, answer: .object([:]), question: shown))
        #expect((sent["question"] as? [String: Any])?["session"] as? String == "local/s1")
    }

    @Test func noDisplayedQuestionSendsNoField() throws {
        let sent = try keys(.init(conversation: "c", messageID: "m", partIndex: 0, answer: .object([:])))
        #expect(sent["question"] == nil)
    }
}
