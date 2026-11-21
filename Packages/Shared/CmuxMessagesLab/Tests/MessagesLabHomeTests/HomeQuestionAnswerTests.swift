import AppKit
import CmuxAgentQuestion
@testable import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// A Home answer to a Chief question goes to the owner only with the person's signed decision.
/// The decider stands in for the native signer (HomeQuestionDecisionSignerTests covers it over a
/// real acpmux line); the store and the mock owner are real.
@MainActor @Suite(.serialized) struct HomeQuestionAnswerTests {
    @MainActor final class Decider: HomeApprovalDeciding, HomeQuestionDeciding {
        var requests: [HomeQuestionRequest] = []
        var result: HomeQuestionDecision
        init(_ result: HomeQuestionDecision) { self.result = result }
        func decide(_ request: HomeApprovalRequest, allow: Bool,
                    through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision { .refused }
        func decide(_ request: HomeQuestionRequest, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeQuestionDecision {
            requests.append(request)
            if case .signed = result, !gate({}) { return .refused }
            return result
        }
    }

    static let decision = #"{"decision_nonce":"aa","person_decision":"bb"}"#

    func question() -> AgentQuestion {
        AgentQuestion(id: "home-question-\(UUID().uuidString)",
                      source: .init(harness: .chief, session: "local/test-subagent", permission: UUID().uuidString),
                      items: [.init(id: "q0", prompt: "Which auth method?",
                                    options: [.init(id: "oauth", label: "OAuth"), .init(id: "keys", label: "API keys")])])
    }

    func posted(_ question: AgentQuestion, in rig: HomeChatRig) async throws -> TranscriptItem {
        let key = IdempotencyKey("question-test-\(UUID().uuidString)")
        #expect(await rig.post([.question(question)], key: key))
        rig.frame()
        return try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == key })
    }

    func current(_ item: TranscriptItem, in rig: HomeChatRig) -> AgentQuestion? {
        guard let current = rig.store.transcript(for: HomeChatRig.conversation).first(where: { $0.key == item.key }),
              case .question(let question)? = current.parts.first else { return nil }
        return question
    }

    static let answer = AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["keys"])])

    @Test func theAnswerReachesTheOwnerWithTheSignedDecision() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let decider = Decider(.signed(Self.decision))
        rig.view.approvals = decider
        let item = try await posted(question(), in: rig)
        let message = try #require(item.messageID)
        let gate = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        let outcome = await rig.view.projection.completeQuestion(chief: rig.chief.rawValue, answer: Self.answer, message: message,
                                                                 partIndex: 0, through: { gate.write($0) })
        #expect(outcome == .answered)
        let request = try #require(decider.requests.first)
        #expect(request.chief == rig.chief.rawValue && request.message == message.rawValue && request.partIndex == 0)
        #expect(try AgentQuestionJSON(data: request.answerJSON) == ["selections": ["q0": ["option_ids": ["keys"]]]])
        #expect(await rig.source.answerDecisions == [Self.decision])
        await HomeChatRig.until { current(item, in: rig)?.isPending == false }
        #expect(!gate.write { Issue.record("one click signed a second answer") })
    }

    @Test(arguments: [HomeQuestionDecision.expired, .refused])
    func withoutADecisionNothingReachesTheOwner(_ result: HomeQuestionDecision) async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        rig.view.approvals = Decider(result)
        let item = try await posted(question(), in: rig)
        let outcome = await rig.view.projection.completeQuestion(chief: rig.chief.rawValue, answer: Self.answer,
                                                                 message: try #require(item.messageID), partIndex: 0,
                                                                 through: { _ in Issue.record("an unsigned answer reached the click"); return false })
        #expect(outcome == (result == .expired ? .expired : .refused))
        #expect(await rig.source.answerDecisions.isEmpty)
        #expect(current(item, in: rig)?.isPending == true)
    }

    @Test func noSignerRefusesTheAnswer() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let item = try await posted(question(), in: rig)
        let outcome = await rig.view.projection.completeQuestion(chief: rig.chief.rawValue, answer: Self.answer,
                                                                 message: try #require(item.messageID), partIndex: 0,
                                                                 through: { _ in false })
        #expect(outcome == .refused)
        #expect(await rig.source.answerDecisions.isEmpty)
    }

    @Test func aScriptedCallWithoutANativeClickAnswersNothing() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let decider = Decider(.signed(Self.decision))
        rig.view.approvals = decider
        let question = question()
        let item = try await posted(question, in: rig)
        let ref = MessagesLabHome.PartRef(messageId: HomeMapping.id(item, aliases: rig.view.projection.aliases), partIndex: 0)
        var outcome: HomeQuestionOutcome?
        #expect(rig.view.projection.answerQuestion(ref, answer: Self.answer) { outcome = $0 })
        #expect(outcome == .refused)
        #expect(decider.requests.isEmpty)
        #expect(current(item, in: rig)?.isPending == true)
    }
}
