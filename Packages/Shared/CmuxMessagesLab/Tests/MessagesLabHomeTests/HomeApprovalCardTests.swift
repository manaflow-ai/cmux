import CmuxAgentQuestion
@testable import CmuxHomeCore
import CmuxHomeRender
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief's permission approval in Home (2026-10-20: a Home "allow" typed as a reply never
/// reached acpmux, which takes an allow only from the person): a Chief `question` part with a
/// `permission` is a card with Allow and Deny, and a click answers acpmux as the person before it
/// answers the part.
@Suite(.serialized) @MainActor struct HomeApprovalCardTests {
    static func approval(harness: AgentQuestion.Harness = .chief, permission: String? = "p1",
                         state: AgentQuestion.State = .pending) -> AgentQuestion {
        AgentQuestion(id: permission ?? "q", source: .init(harness: harness, session: "s1", permission: permission, agentName: "Chief"),
                      items: [.init(id: "approval", header: "Approval", prompt: "Bash wants to run: ls -la",
                                    options: [.init(id: "allow", label: "Allow"), .init(id: "deny", label: "Deny")],
                                    allowsOther: false)],
                      state: state)
    }

    static func card(_ part: Part?) -> HomeApprovalRowProvider.Payload? {
        guard case .custom(let c)? = part, c.kind == HomeApprovalRowProvider.kind else { return nil }
        return HomeApprovalRowProvider.payload(c)
    }

    func mapped(_ question: AgentQuestion) -> Part? {
        CustomRows.register(HomeApprovalRowProvider.shared)
        defer { CustomRows.unregister(HomeApprovalRowProvider.kind) }
        return HomeMapping.parts(.question(question)).first
    }

    // MARK: Mapping

    @Test func aPendingChiefApprovalIsACardWithButtons() throws {
        let card = try #require(Self.card(mapped(Self.approval())))
        #expect(card.status == .pending)
        #expect(card.session == "s1" && card.permission == "p1")
        #expect(card.prompt == "Bash wants to run: ls -la")
        let layout = HomeApprovalRowProvider.layout(card, width: 300)
        #expect(layout.allow != nil && layout.deny != nil)
    }

    @Test func anAnsweredOrCancelledApprovalIsOneLine() throws {
        let respondent = AgentQuestionAnswer.Respondent(participant: "user_local", device: "Lawrence's iPhone", isRemote: true)
        let allowed = AgentQuestionAnswer(selections: ["approval": .init(optionIDs: ["allow"])], respondent: respondent)
        let card = try #require(Self.card(mapped(Self.approval(state: .answered(allowed)))))
        #expect(card.status == .allowed && card.device == "Lawrence's iPhone")
        #expect(HomeApprovalRowProvider.layout(card, width: 300).allow == nil)
        #expect(HomeApprovalRowProvider.lineText(card) == CmuxStrings.approvalAllowedOn("Lawrence's iPhone"))

        let denied = AgentQuestionAnswer(selections: ["approval": .init(optionIDs: ["deny"])])
        #expect(try #require(Self.card(mapped(Self.approval(state: .answered(denied))))).status == .denied)
        #expect(try #require(Self.card(mapped(Self.approval(state: .cancelled)))).status == .skipped)
    }

    @Test func anyOtherQuestionStaysText() {
        #expect(Self.card(mapped(Self.approval(harness: .claude))) == nil)
        #expect(Self.card(mapped(Self.approval(permission: nil))) == nil)
        // Without the provider registered, a Chief approval is its text too.
        #expect(Self.card(HomeMapping.parts(.question(Self.approval())).first) == nil)
    }

    // MARK: Hit test

    @Test func theButtonsHitTestInTheBody() throws {
        let card = try #require(Self.card(mapped(Self.approval())))
        let layout = HomeApprovalRowProvider.layout(card, width: 300)
        let allow = try #require(layout.allow), deny = try #require(layout.deny)
        #expect(HomeApprovalRowProvider.button(at: CGPoint(x: allow.midX, y: allow.midY), card, width: layout.size.width) == true)
        #expect(HomeApprovalRowProvider.button(at: CGPoint(x: deny.midX, y: deny.midY), card, width: layout.size.width) == false)
        // The prompt is not a button.
        #expect(HomeApprovalRowProvider.button(at: CGPoint(x: allow.midX, y: 4), card, width: layout.size.width) == nil)
        // The rects fit the measured card.
        #expect(deny.maxX <= layout.size.width && deny.maxY <= layout.size.height)
    }

    @Test func aRefusalShowsUnderTheButtonsAndTheyStay() throws {
        var card = try #require(Self.card(mapped(Self.approval())))
        let before = HomeApprovalRowProvider.layout(card, width: 300)
        card.error = "The Chief did not accept this app as you"
        let after = HomeApprovalRowProvider.layout(card, width: 300)
        #expect(after.allow == before.allow && after.deny != nil)
        #expect(after.size.height > before.size.height)
        #expect(HomeApprovalRowProvider.lineText(card) == CmuxStrings.approvalRefused("The Chief did not accept this app as you"))
    }

    // MARK: Decision path

    @MainActor final class FakeDecider: HomeApprovalDeciding {
        struct Refused: LocalizedError { var errorDescription: String? { "acpmux said no" } }
        var calls: [(String, String, Bool)] = []
        var fails = false
        func decide(session: String, permission: String, allow: Bool) async throws {
            calls.append((session, permission, allow))
            if fails { throw Refused() }
        }
    }

    /// The rig's conversation with one Chief approval posted; its message id and the store part.
    func posted(_ rig: HomeChatRig) async throws -> MessageID {
        let key = IdempotencyKey.make()
        _ = await rig.source.post(parts: [.question(Self.approval())], from: rig.chief, in: HomeChatRig.conversation, key: key)
        await HomeChatRig.until { rig.store.transcript(for: HomeChatRig.conversation).contains { $0.key == key && $0.seq != nil } }
        let item = try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == key })
        return try #require(item.messageID)
    }

    func part(_ rig: HomeChatRig, _ message: MessageID) -> AgentQuestion? {
        guard let item = rig.store.transcript(for: HomeChatRig.conversation).first(where: { $0.messageID == message }),
              case .question(let q)? = item.parts.first else { return nil }
        return q
    }

    @Test func anAllowAnswersAcpmuxThenThePart() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(message: message, partIndex: 0, session: "s1", permission: "p1", allow: true)
        #expect((try? result.get()) != nil)
        #expect(decider.calls.count == 1 && decider.calls.first?.2 == true)
        await HomeChatRig.until { part(rig, message)?.isPending == false }
        guard case .answered(let answer)? = part(rig, message)?.state else { Issue.record("not answered"); return }
        #expect(answer.selections["approval"]?.optionIDs == ["allow"])
    }

    @Test func aRefusedAllowAnswersNothing() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        decider.fails = true
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(message: message, partIndex: 0, session: "s1", permission: "p1", allow: true)
        #expect(result == .failure(.refused("acpmux said no")))
        rig.frame()
        #expect(part(rig, message)?.isPending == true, "the card takes input again")
    }

    @Test func aRefusedDenyStillAnswersThePart() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        decider.fails = true
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(message: message, partIndex: 0, session: "s1", permission: "p1", allow: false)
        #expect((try? result.get()) != nil, "the Chief denies on the card's answer")
        await HomeChatRig.until { part(rig, message)?.isPending == false }
        guard case .answered(let answer)? = part(rig, message)?.state else { Issue.record("not answered"); return }
        #expect(answer.selections["approval"]?.optionIDs == ["deny"])
    }

    @Test func withoutADeciderAllowSaysWhereToAnswer() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        rig.view.projection.approvals = nil
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(message: message, partIndex: 0, session: "s1", permission: "p1", allow: true)
        #expect(result == .failure(.unavailable))
    }
}

extension Result where Success == Void, Failure == HomeApprovalFailure {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success): true
        case (.failure(let a), .failure(let b)): a == b
        default: false
        }
    }
}
