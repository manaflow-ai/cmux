import CmuxAgentQuestion
@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// Approval cards as Home answers them: `HomeOp.answerQuestion` addressing the
/// approval part, the card replacing its tool's running row, the typing dots off
/// while it waits, Stop settling it, and "Always Allow" rules.
@Suite struct ChiefApprovalCardTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    private static func answer(_ choice: String, always: Bool = false) -> AgentQuestionAnswer {
        var selections = [ChiefConversationOwner.approvalAnswerItem: AgentQuestionAnswer.Selection(optionIDs: [choice])]
        if always { selections[ChiefConversationOwner.approvalAlwaysItem] = AgentQuestionAnswer.Selection(optionIDs: ["1"]) }
        return AgentQuestionAnswer(selections: selections)
    }

    /// A brain that starts `cmux tree --all`, asks to run it, and waits at `gate`.
    private static func askingBrain(_ gate: Gate) -> FakeBrain {
        FakeBrain { _, continuation in
            continuation.yield(.toolStarted(id: "t1", title: "cmux tree --all", detail: "cmux tree --all"))
            continuation.yield(.approvalRequested(id: "perm-1", prompt: "Run `cmux tree --all`?", options: ["Allow", "Deny"]))
            await gate.wait()
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    @Test func theCardReplacesItsToolRowAndTheChiefStopsTyping() async throws {
        let gate = Gate()
        let owner = try ChiefFixture().owner(Self.askingBrain(gate))
        let recorder = EventRecorder()
        await recorder.start(owner)
        try await ChiefFixture.send("show my workspaces", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWaitingForApproval(conversation) })

        // One Chief message: the approval took the running tool row's place (the command shows once).
        let messages = try await owner.snapshot(of: conversation, tail: 10).messages
        #expect(messages.count == 2)
        let card = try #require(messages.last)
        guard case .approval(let ref) = card.parts.first, card.parts.count == 1 else { Issue.record("no approval part"); return }
        #expect(ref.request == "perm-1")
        #expect(await owner.pendingApproval(in: conversation)?.request == "perm-1")

        // No typing dots under a card that waits for the user.
        let events = await recorder.events
        let lastTyping = events.last { if case .typing = $0 { return true }; return false }
        guard case .typing(_, _, on: let on)? = lastTyping else { Issue.record("no typing event"); return }
        #expect(on == false)

        // Home's answer: answerQuestion on the approval part.
        try await owner.submit(HomeIntent(op: .answerQuestion(message: card.id, conversation: conversation, partIndex: 0,
                                                              answer: Self.answer("Allow"))))
        let decided = try await owner.snapshot(of: conversation, tail: 10).messages.last
        guard case .approval(let answered)? = decided?.parts.first else { Issue.record("no approval part"); return }
        #expect(answered.decided == "Allow")
        #expect(await owner.isWaitingForApproval(conversation) == false)
        #expect(await owner.pendingApproval(in: conversation) == nil)
        #expect(await ChiefFixture.eventually { await owner.brainApprovals() == ["perm-1:Allow"] })
        // The Chief types again while its turn goes on.
        #expect(await ChiefFixture.eventually {
            await recorder.events.last { if case .typing = $0 { return true }; return false }
                .map { if case .typing(_, _, on: true) = $0 { return true }; return false } ?? false
        })
        // A second answer is refused.
        await #expect(throws: HomeRejection.invalid("approval_decided")) {
            try await owner.submit(HomeIntent(op: .answerQuestion(message: card.id, conversation: self.conversation, partIndex: 0,
                                                                  answer: Self.answer("Deny"))))
        }
        await gate.open()
    }

    @Test func stopSettlesAWaitingCardAsDenied() async throws {
        let gate = Gate()
        let owner = try ChiefFixture().owner(Self.askingBrain(gate))
        try await ChiefFixture.send("show my workspaces", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWaitingForApproval(conversation) })
        #expect(await owner.stopTurn(conversation: conversation))
        let card = try await owner.snapshot(of: conversation, tail: 10).messages.last
        guard case .approval(let ref)? = card?.parts.first else { Issue.record("no approval part"); return }
        #expect(ref.decided == "Deny")
        await gate.open()
    }

    @Test func alwaysAllowSavesTheCommandsRule() async throws {
        let gate = Gate()
        let fixture = ChiefFixture()
        let brain = FakeBrain { _, continuation in
            continuation.yield(.approvalRequested(id: "perm-2", prompt: "Run `acme-deploy ship --dry-run`?", options: ["Allow", "Deny"]))
            await gate.wait()
            continuation.finish()
        }
        let owner = try fixture.owner(brain)
        try await ChiefFixture.send("ship it", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWaitingForApproval(conversation) })
        let card = try #require(try await owner.snapshot(of: conversation, tail: 10).messages.last)
        try await owner.submit(HomeIntent(op: .answerQuestion(message: card.id, conversation: conversation, partIndex: 0,
                                                              answer: Self.answer("Allow", always: true))))
        #expect(ChiefAllowRules.shared.all.contains(["acme-deploy", "ship"]))
        #expect(ChiefToolPolicy.autoAllowsCommand("acme-deploy ship --prod"))
        // Only that subcommand, one simple command at a time.
        #expect(!ChiefToolPolicy.autoAllowsCommand("acme-deploy destroy"))
        #expect(!ChiefToolPolicy.autoAllowsCommand("acme-deploy ship $(whoami)"))
        let file = fixture.home.stateDirectory.appendingPathComponent("allow-rules.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        await gate.open()
    }

    @Test func rulesAreOfferedOnlyForPlainSubcommands() {
        #expect(ChiefAllowRules.prefix(for: "cmux tree --all") == ["cmux", "tree"])
        #expect(ChiefAllowRules.prefix(for: "git push origin main") == ["git", "push"])
        #expect(ChiefAllowRules.prefix(for: "cmux tree --all 2>&1 | head -100") == nil)
        #expect(ChiefAllowRules.prefix(for: "rm -rf build") == nil)
        #expect(ChiefAllowRules.prefix(for: "bash -c ls") == nil)
        #expect(ChiefAllowRules.prefix(for: "cmux close-workspace") == nil)
        #expect(ChiefAllowRules.prefix(for: "cmux kill") == nil)
        #expect(ChiefAllowRules.prefix(for: "ls") == nil)
        #expect(ChiefAllowRules.command(inPrompt: "Run `cmux tree --all`?") == "cmux tree --all")
        #expect(ChiefAllowRules.command(inPrompt: "Allow Edit README.md?") == nil)
    }
}

extension ChiefConversationOwner {
    /// The approvals the fake brain heard, as "id:choice".
    func brainApprovals() async -> [String] {
        guard let fake = brain as? FakeBrain else { return [] }
        return await fake.log.approvals.map { "\($0.id):\($0.choice)" }
    }
}
