import CmuxHomeRender
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
@testable import CmuxNextHomeEngine
import Testing

@MainActor @Suite struct ChiefApprovalDeciderTests {
    @Test func anUnavailableDaemonLeavesTheCardRetryable() async {
        let home = ChiefHome(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), isolated: true)
        await confirmation("Both candidate homes are resolved", expectedCount: 2) { resolved in
            let decider = ChiefApprovalDecider(home: home, app: nil, work: .init(), environment: { _ in
                resolved()
                return nil
            })
            let result = await decider.decide(
                .init(chief: "agent_mux", session: "local/approval-test", permission: "permission-1",
                      requestJSON: #"{"toolCall":{"title":"Bash","rawInput":{"command":"printf approval-test"}},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}"#),
                allow: true,
                through: { _ in
                    Issue.record("An unavailable daemon must not spend the native click")
                    return false
                }
            )
            #expect(result == .refused, "An unavailable daemon is retryable, not evidence that the request expired")
        }
    }

    static let requestJSON = #"{"toolCall":{"title":"Bash","rawInput":{"command":"printf approval-test"}},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}"#
    static let record = HomeQuestionRequest(chief: "agent_mux", conversation: "c1", message: "m1", partIndex: 0,
                                            answerJSON: Data(#"{"selections":{"approval:x":{"option_ids":["allow"]}}}"#.utf8))

    func decider(stored: (@MainActor (HomeQuestionRequest) async throws -> String)?, resolved: @escaping @Sendable () -> Void = {}) -> ChiefApprovalDecider {
        let home = ChiefHome(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), isolated: true)
        let decider = ChiefApprovalDecider(home: home, app: nil, work: .init(), environment: { _ in resolved(); return nil })
        decider.storedApprovalQuestion = stored
        return decider
    }

    static let noClick: @Sendable (() -> Void) -> Bool = { _ in
        Issue.record("the native click must not be spent")
        return false
    }

    /// A card that asks for its record reads the stored card before anything is answered: a
    /// closed card is expired, an unreadable one refused, and neither reaches acpmux or the click.
    @Test func theStoredCardIsReadBeforeAnythingIsAnswered() async {
        let request = HomeApprovalRequest(chief: "agent_mux", session: "local/approval-test", permission: "permission-1",
                                          requestJSON: Self.requestJSON, record: Self.record)
        let closed = decider(stored: { _ in throw DaemonError.command(cmd: "conversation-question-decision", message: "closed", code: "question.closed") },
                             resolved: { Issue.record("a closed card must not look for a daemon") })
        #expect(await closed.decide(request, allow: true, through: Self.noClick) == .expired)
        let down = decider(stored: { _ in throw DaemonError.notConnected }, resolved: { Issue.record("an unread card must not look for a daemon") })
        #expect(await down.decide(request, allow: true, through: Self.noClick) == .refused)
        let none = decider(stored: nil, resolved: { Issue.record("no record reader must not look for a daemon") })
        #expect(await none.decide(request, allow: true, through: Self.noClick) == .refused)
        let notCard = decider(stored: { _ in #"{"other":1}"# }, resolved: { Issue.record("a reply with no question must not look for a daemon") })
        #expect(await notCard.decide(request, allow: true, through: Self.noClick) == .refused)
    }

    /// Only a gone or changed question is expired; anything else keeps the card retryable.
    @Test func onlyAGoneQuestionIsExpired() {
        for code in ["question.closed", "question.stale", "question.not_found"] {
            #expect(ChiefApprovalDecider.questionEnded(DaemonError.command(cmd: "x", message: "", code: code)))
        }
        for code in ["question.agent_gone", "question.agent_busy", "question.refused", "conversation_rejected"] {
            #expect(!ChiefApprovalDecider.questionEnded(DaemonError.command(cmd: "x", message: "", code: code)))
        }
        #expect(!ChiefApprovalDecider.questionEnded(DaemonError.command(cmd: "x", message: "", code: nil)))
        #expect(!ChiefApprovalDecider.questionEnded(DaemonError.notConnected))
    }

    /// A question whose decision the owner refuses as gone is expired, not a failure to retry.
    @Test func aGoneQuestionsDecisionIsExpired() async {
        let decider = decider(stored: nil)
        decider.unsignedQuestionDecision = { _ in throw DaemonError.command(cmd: "conversation-question-decision", message: "", code: "question.stale") }
        #expect(await decider.decide(Self.record, through: Self.noClick) == .expired)
        decider.unsignedQuestionDecision = { _ in throw DaemonError.command(cmd: "conversation-question-decision", message: "", code: "question.agent_busy") }
        #expect(await decider.decide(Self.record, through: Self.noClick) == .refused)
    }

    /// The record is the stored question unchanged and the receipt reference, under
    /// `native_record`, with exactly the four keys the owner reads and no proof.
    @Test func theNativeRecordIsTheStoredQuestionAndTheReceipt() throws {
        let question: [String: Any] = ["harness": "chief", "session": "s1", "permission": "p1",
                                       "items": [["id": "approval:" + String(repeating: "a", count: 64), "prompt": "Run \"ls\" ✓ /tmp?",
                                                  "multi_select": false, "allows_other": false,
                                                  "options": [["id": "allow", "label": "Allow"], ["id": "deny", "label": "Deny"]]]],
                                       "state": ["kind": "pending"]]
        let receipt = AcpmuxDeliveryReceipt(id: "home-approval-1", instance: "0123456789abcdef", decisionNonce: String(repeating: "c", count: 64))
        let text = try #require(ChiefApprovalDecider.nativeRecord(question: question, receipt: receipt))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(root.keys) == ["native_record"])
        let record = try #require(root["native_record"] as? [String: Any])
        #expect(Set(record.keys) == ["question", "receipt_id", "instance", "decision_nonce"])
        #expect(record["receipt_id"] as? String == "home-approval-1")
        #expect(record["instance"] as? String == "0123456789abcdef")
        #expect(record["decision_nonce"] as? String == String(repeating: "c", count: 64))
        #expect(NSDictionary(dictionary: try #require(record["question"] as? [String: Any])).isEqual(to: question))
        #expect(!text.contains("person_decision"))
    }
}
