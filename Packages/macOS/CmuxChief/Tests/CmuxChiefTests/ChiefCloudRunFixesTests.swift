import CmuxAgentQuestion
@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// What the real Cloud run (chief-dogfood-1) got wrong on the owner's side: a question card
/// answered by typing stayed live, every `vm exec` probe asked with no Always Allow, a sign-in
/// screen read as a failure, and the prompt pushed a 17 GB checkout.
@Suite struct ChiefCloudRunFixesTests {
    let conversation = ChiefConversationOwner.defaultConversationID
    typealias FollowUp = ChiefCloudFollowUpTests

    // MARK: Typed answers

    @Test func chatTextAnswersACardOnlyWhenItNamesEveryItem() throws {
        let one = FollowUp.question([FollowUp.machine])
        for text in ["4 GB", "4 gb.", "Machine: 4 GB", "My answer to your question:\nMachine: 4 GB", "  4g!"] {
            let answer = try #require(ChiefQuestionAnswer.fromChat(text, question: one), "\(text)")
            #expect(answer.selections["machine"]?.optionIDs == ["4g"], "\(text)")
        }
        #expect(ChiefQuestionAnswer.fromChat("8 GB please", question: one) == nil)
        #expect(ChiefQuestionAnswer.fromChat("actually, use the existing machine", question: one) == nil)
        // Two items: naming one is not an answer (no silent preselection from chat).
        let two = FollowUp.question([FollowUp.machine, FollowUp.name])
        #expect(ChiefQuestionAnswer.fromChat("8 GB", question: two) == nil)
        let both = try #require(ChiefQuestionAnswer.fromChat("8 GB\nweb", question: two))
        #expect(both.selections["machine"]?.optionIDs == ["8g"])
        #expect(both.selections["name"]?.optionIDs == ["web"])
    }

    private func cardOwner() async throws -> (ChiefConversationOwner, FakeBrain, ChiefConversationOwner.PendingQuestion) {
        let card = FollowUp.question([FollowUp.machine])
        let brain = FakeBrain { request, continuation in
            if request.userText == "set up a machine" { continuation.yield(.question(card)) }
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("set up a machine", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        let pending = try #require(await owner.pendingQuestion(in: conversation))
        return (owner, brain, pending)
    }

    private func storedQuestion(_ owner: ChiefConversationOwner, _ message: MessageID) async throws -> AgentQuestion? {
        let messages = try await owner.snapshot(of: conversation, tail: 20).messages
        guard case .question(let question)? = messages.first(where: { $0.id == message })?.parts.first else { return nil }
        return question
    }

    @Test func aTypedChoiceAnswersTheCardAndTheChiefHearsTheMessage() async throws {
        let (owner, brain, pending) = try await cardOwner()
        try await ChiefFixture.send("8 GB", to: owner)
        let stored = try #require(try await storedQuestion(owner, pending.message))
        guard case .answered(let answer) = stored.state else { Issue.record("the card still waits"); return }
        #expect(answer.selections["machine"]?.optionIDs == ["8g"])
        #expect(stored.summaryLines(answer) == ["Machine: 8 GB"])
        #expect(await owner.pendingQuestion(in: conversation) == nil)
        // One turn for the typed message, with the user's own words.
        #expect(await ChiefFixture.eventually { await brain.log.requests.count == 2 })
        #expect(await brain.log.requests.last?.userText == "8 GB")
    }

    @Test func otherTypedTextClosesTheCardAsAnsweredInChat() async throws {
        let (owner, _, pending) = try await cardOwner()
        try await ChiefFixture.send("Use my existing machine instead", to: owner)
        let stored = try #require(try await storedQuestion(owner, pending.message))
        #expect(stored.state == .cancelled)
        #expect(await owner.pendingQuestion(in: conversation) == nil)
    }

    // MARK: Always Allow for one machine's vm exec

    @Test func vmExecGetsAnAlwaysAllowRuleForItsMachineOnly() throws {
        #expect(ChiefAllowRules.prefix(for: "cmux vm exec chief-dogfood-1 -- pwd") == ["cmux", "vm", "exec", "chief-dogfood-1"])
        #expect(ChiefAllowRules.prefix(for: "cmux vm exec --timeout 600 vm-794a -- git clone --depth 1 https://x/y work/y")
            == ["cmux", "vm", "exec", "vm-794a"])
        #expect(ChiefAllowRules.prefix(for: "cmux cloud exec vm-794a -- id") == ["cmux", "vm", "exec", "vm-794a"])
        #expect(ChiefToolPolicy.approvalOptions(command: "cmux vm exec vm-794a -- sh -c 'HOME=/home/cmux codex login status'")
            == ["Allow", "Deny", "always:cmux vm exec vm-794a"])
        // No rule for another vm verb, a forged machine, an unknown flag, or a remote cmux call.
        for command in [
            "cmux vm rm vm-794a", "cmux vm exec -- id", "cmux vm exec --force vm-794a -- id", "cmux vm exec 'a b' -- id",
            "cmux vm exec vm-794a -- cmux vm rm other", "cmux vm exec vm-794a extra -- id",
        ] {
            #expect(ChiefAllowRules.prefix(for: command) == nil, "\(command)")
        }

        let rules = ChiefAllowRules()
        #expect(try rules.add(command: "cmux vm exec vm-794a -- pwd") == ["cmux", "vm", "exec", "vm-794a"])
        #expect(rules.allows(["cmux", "vm", "exec", "vm-794a", "--", "rm", "-rf", "work/old"]))
        #expect(rules.allows(["cmux", "vm", "exec", "--timeout", "600", "vm-794a", "--", "git", "clone", "u", "work/x"]))
        #expect(!rules.allows(["cmux", "vm", "exec", "other-machine", "--", "pwd"]))
        #expect(!rules.allows(["cmux", "vm", "rm", "vm-794a"]))
        #expect(!rules.allows(["cmux", "vm", "pause", "vm-794a"]))
        #expect(!rules.allows(["cmux", "vm", "exec", "vm-794a", "--", "sh", "-c", "cmux vm rm other"]))
    }

    @Test func aMachineRuleSurvivesTheRulesFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root)
        let writer = ChiefAllowRules()
        writer.load(home)
        try writer.add(rule: ["cmux", "vm", "exec", "vm-794a"])
        let reader = ChiefAllowRules()
        reader.load(home)
        #expect(reader.all == [["cmux", "vm", "exec", "vm-794a"]])
        #expect(reader.allows(["cmux", "vm", "exec", "vm-794a", "--", "pwd"]))
    }

    // MARK: Sign-in result

    @Test func aSignInResultIsStoredAsWaitingAndOutlivesARelaunch() {
        let card = ChiefResultCard(title: "Codex needs sign-in on chief-dogfood-1", subtitle: "Open the workspace and choose Sign in with Device Code",
                                   machine: "vm-794a", workspace: "ws_962f", status: .needsSignIn)
        #expect(ChiefResultCard.Status(rawValue: "needs_sign_in") == .needsSignIn)
        let work = ChiefConversationOwner.resultWork(card)
        #expect(work.status == .waiting && work.host == "vm-794a" && work.session == "ws_962f")

        let summary = ConversationSummary(id: conversation, owner: .local, participants: [], createdAt: Date(), updatedAt: Date())
        func message(_ seq: Int, _ part: MessagePart) -> Message {
            Message(id: MessageID("msg_\(seq)"), conversation: conversation, seq: Seq(seq), clientMessageID: .make(),
                    author: ChiefConversationOwner.userID, parts: [part], createdAt: Date())
        }
        var state = ChiefConversationState(summary: summary, messages: [
            message(1, .work(work)),
            message(2, .work(WorkRef(session: "call-1", title: "git clone", status: .running))),
        ])
        ChiefConversationOwner.settleInterrupted(&state)
        let statuses = state.messages.compactMap { message -> WorkRef.Status? in
            if case .work(let w)? = message.parts.first { return w.status }
            return nil
        }
        // The remote agent's card keeps its state; the local call that never finished fails.
        #expect(statuses == [.waiting, .failed])
    }

    // MARK: Prompt

    @Test func thePromptTeachesTheMachineHomeSignInStopAndLargePushes() {
        let prompt = ChiefSystemPrompt(context: ChiefPromptContext()).build()
        for rule in [
            "/home/cmux", "Never probe for the home", "one `cmux vm exec <machine> -- pwd`",
            "HOME=/home/cmux codex login status", "HOME=/home/cmux claude auth status --text", "\"needs_sign_in\"",
            "Do not launch the agent", "Sign in with Device Code", "cmux ai-accounts upload codex", "run it only after they say yes",
            "/home/cmux/work/<slug>", "does not promise a writable current directory", "Never push `/Users/cmux/manaflow/cmuxterm-hq`",
            "cd /home/cmux/work/<slug>",
            "cmux vm pause <machine>", "Stop cloud machine <name> (<machine>)", "--allow-large", "Prefer a clone",
            "cmux vm open <machine>:desktop", "cua-driver doctor", "cua-driver list-tools", "cua-driver call <tool> '<json>'",
            "gently offer the cmux Pro upgrade",
        ] {
            #expect(prompt.contains(rule), "missing \(rule)")
        }
        #expect(!prompt.contains("Not signed in: start it anyway"))
        #expect(prompt.contains("Use plain `exec codex` or `exec claude`"))
        #expect(!prompt.contains("exec codex --yolo '<task>'"))
        let optedIn = ChiefSystemPrompt(context: ChiefPromptContext(dangerouslySkipPermissions: true)).build()
        #expect(optedIn.contains("add `--yolo` only when it is appropriate"))
    }
}
