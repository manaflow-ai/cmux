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
        // The card's id is the brain's id in the turn's namespace; the brain hears its own id.
        #expect(ref.request.hasSuffix(":perm-1") && ref.request != "perm-1")
        #expect(await owner.pendingApproval(in: conversation) == ChiefConversationOwner.PendingApproval(message: card.id, part: 0, ref: ref))

        // No typing dots under a card that waits for the user (the recorder hears events on its own task).
        #expect(await ChiefFixture.eventually {
            let lastTyping = await recorder.events.last { if case .typing = $0 { return true }; return false }
            guard case .typing(_, _, on: let on)? = lastTyping else { return false }
            return on == false
        })

        // Home's answer: answerQuestion on the approval part.
        try await owner.submit(HomeIntent(op: .answerQuestion(message: card.id, conversation: conversation, partIndex: 0,
                                                              answer: Self.answer("Allow"))))
        let after = try await owner.snapshot(of: conversation, tail: 10).messages
        let decided = after.first { $0.id == card.id }
        guard case .approval(let answered)? = decided?.parts.first else { Issue.record("no approval part"); return }
        #expect(answered.decided == "Allow")
        // Allowed, the tool's running row comes back right under the receipt (Home folds them into
        // "Ran cmux tree --all · Allowed"), and the row's spinner is the one live indicator: no typing dots.
        #expect(after.count == 3)
        guard case .work(let row)? = after.last?.parts.first else { Issue.record("no tool row after the receipt"); return }
        #expect(row.title == "cmux tree --all" && row.status == .running)
        #expect(await owner.isWaitingForApproval(conversation) == false)
        #expect(await owner.pendingApproval(in: conversation) == nil)
        #expect(await ChiefFixture.eventually { await owner.brainApprovals() == ["perm-1:Allow"] })
        let typing = await recorder.events.last { if case .typing = $0 { return true }; return false }
        guard case .typing(_, _, on: let typingAfter)? = typing else { Issue.record("no typing event"); return }
        #expect(typingAfter == false)
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
        let card = try await owner.snapshot(of: conversation, tail: 10).messages.last {
            if case .approval = $0.parts.first { return true }
            return false
        }
        guard case .approval(let ref)? = card?.parts.first else { Issue.record("no approval part"); return }
        #expect(ref.decided == "Deny")
        await gate.open()
    }

    @Test func alwaysAllowSavesTheCommandsRule() async throws {
        let gate = Gate()
        let fixture = ChiefFixture()
        let brain = FakeBrain { _, continuation in
            continuation.yield(.approvalRequested(id: "perm-2", prompt: "Run `acme-deploy ship --dry-run`?",
                                                  options: ChiefToolPolicy.approvalOptions(command: "acme-deploy ship --dry-run")))
            await gate.wait()
            continuation.finish()
        }
        let owner = try fixture.owner(brain)
        try await ChiefFixture.send("ship it", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWaitingForApproval(conversation) })
        let card = try #require(try await owner.snapshot(of: conversation, tail: 10).messages.last)
        guard case .approval(let ref)? = card.parts.first else { Issue.record("no approval part"); return }
        // The card carries the rule it offers; that option is never an answer.
        #expect(ref.options == ["Allow", "Deny", "always:acme-deploy ship"])
        await #expect(throws: (any Error).self) {
            try await owner.submit(HomeIntent(op: .answerQuestion(message: card.id, conversation: conversation, partIndex: 0,
                                                                  answer: Self.answer("always:acme-deploy ship"))))
        }
        try await owner.submit(HomeIntent(op: .answerQuestion(message: card.id, conversation: conversation, partIndex: 0,
                                                              answer: Self.answer("Allow", always: true))))
        #expect(fixture.allowRules.all.contains(["acme-deploy", "ship"]))
        #expect(ChiefToolPolicy.autoAllowsCommand("acme-deploy ship --prod", allowRules: fixture.allowRules))
        // Only that subcommand, one simple command at a time.
        #expect(!ChiefToolPolicy.autoAllowsCommand("acme-deploy destroy", allowRules: fixture.allowRules))
        #expect(!ChiefToolPolicy.autoAllowsCommand("acme-deploy ship $(whoami)", allowRules: fixture.allowRules))
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

    /// (command, rule offered). Home's card has the same table (ChiefRowsTests.alwaysAllowCases); change both.
    static let ruleCases: [(String, [String]?)] = [
        ("cmux tree --all", ["cmux", "tree"]),
        ("git push origin main", ["git", "push"]),
        ("cmux workspace rename workspace:2 --title API", ["cmux", "workspace"]),
        ("cmux chief dispatch --agent codex --name fix", ["cmux", "chief", "dispatch"]),
        // destructive cmux verbs, by word, prefix or value
        ("cmux close-workspace --workspace workspace:2", nil),
        ("cmux kill-pane --pane pane:2", nil),
        ("cmux clear-notifications", nil),
        ("cmux workspace close workspace:2", nil),
        ("cmux tree --force", nil),
        ("cmux tree --force=true", nil),
        ("cmux workspace create --command id", nil),
        // cmux groups that run commands, type or answer for the user
        ("cmux send --workspace workspace:2 hi", nil),
        ("cmux send-key --workspace workspace:2 enter", nil),
        // `vm exec` gets a rule for its one machine (ChiefAllowRules.vmExecRule).
        ("cmux vm exec brave-otter -- id", ["cmux", "vm", "exec", "brave-otter"]),
        ("cmux vm run brave-otter id", nil),
        ("cmux vm ls", nil),
        ("cmux vm new --detach", nil),
        ("cmux chief approve", nil),
        ("cmux chief send hi", nil),
        ("cmux chief memory add fact", nil),
        ("cmux chief", nil),
        ("cmux browser eval 1", nil),
        ("cmux new-workspace --name x", nil),
        ("cmux rpc workspace.close", nil),
        // shells, interpreters, runners
        ("bash -c ls", nil), ("sh script", nil), ("zsh -lc x", nil), ("python script.py", nil), ("python3 -m http", nil),
        ("node app.js", nil), ("ruby x.rb", nil), ("perl x.pl", nil), ("npx something", nil), ("make all", nil),
        ("npm exec foo", nil), ("npm run build", nil), ("git config user.email", nil), ("env cmux tree", nil),
        ("rm -rf build", nil), ("ls", nil),
        // syntax the rule cannot see through
        ("cmux tree --all 2>&1 | head -100", nil), ("cmux clo{s,}e-workspace", nil), ("cmux tree *", nil),
        ("cmux tree ~", nil), ("git diff --output=x", nil), ("cmux tree $HOME", nil), ("cmux tree; cmux kill", nil),
        // quotes are lexed away: the words decide
        (##"cmux chief dispatch --agent codex --name "#123: fix login" -- 'Fix it, then report.'"##, ["cmux", "chief", "dispatch"]),
        (#"git commit -m "fix: it's done""#, ["git", "commit"]),
        (##"cmux workspace rename workspace:2 --title 'API #2'"##, ["cmux", "workspace"]),
        (#"cmux 'close-workspace'"#, nil),
    ]

    @Test(arguments: ruleCases.indices)
    func ruleOffers(index: Int) {
        let (command, rule) = Self.ruleCases[index]
        #expect(ChiefAllowRules.prefix(for: command) == rule, "\(command)")
    }

    @Test func aRuleNeverCoversADestructiveCallOrAnotherGroupVerb() throws {
        let rules = ChiefAllowRules()
        #expect(try rules.add(command: "cmux workspace rename workspace:2 --title x") == ["cmux", "workspace"])
        #expect(try rules.add(command: "cmux chief dispatch --agent codex") == ["cmux", "chief", "dispatch"])
        #expect(rules.allows(["cmux", "workspace", "select", "workspace:2"]))
        #expect(rules.allows(["cmux", "chief", "dispatch", "--name", "x"]))
        for words in [
            ["cmux", "workspace", "close", "workspace:2"], ["cmux", "workspace", "create", "--command", "id"],
            ["cmux", "workspace", "rename", "--force=true"], ["cmux", "workspace", "kill-all"],
            ["cmux", "chief", "approve"], ["cmux", "chief", "send", "hi"], ["cmux", "chief", "memory", "add", "x"],
        ] {
            #expect(!rules.allows(words), "\(words)")
        }
    }

    @Test func ineligibleRulesOnDiskAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root)
        try FileManager.default.createDirectory(at: home.stateDirectory, withIntermediateDirectories: true)
        let stored = #"{"rules":[["cmux","vm"],["cmux","send"],["bash","-c"],["cmux","chief"],["git","config"],["cmux","tree"]]}"#
        try Data(stored.utf8).write(to: home.stateDirectory.appendingPathComponent("allow-rules.json"))
        let rules = ChiefAllowRules()
        rules.load(home)
        #expect(!rules.allows(["cmux", "vm", "exec", "m", "--", "id"]))
        #expect(!rules.allows(["cmux", "send", "hi"]))
        #expect(!rules.allows(["bash", "-c", "id"]))
        #expect(!rules.allows(["cmux", "chief", "approve"]))
        #expect(!rules.allows(["git", "config", "core.pager", "sh"]))
        #expect(rules.allows(["cmux", "tree", "--all"]))
    }

    @Test func changingHomesDoesNotCarryAlwaysAllowRulesAcrossHomes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-rules-homes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ChiefHome(root: root.appendingPathComponent("first"))
        let second = ChiefHome(root: root.appendingPathComponent("second"))
        let rules = ChiefAllowRules()
        rules.load(first)
        #expect(try rules.add(rule: ["git", "status"]) == ["git", "status"])
        rules.load(second)
        #expect(rules.all.isEmpty)
        #expect(!rules.allows(["git", "status"]))
    }
}

extension ChiefConversationOwner {
    /// The approvals the fake brain heard, as "id:choice".
    func brainApprovals() async -> [String] {
        guard let fake = brain as? FakeBrain else { return [] }
        return await fake.log.approvals.map { "\($0.id):\($0.choice)" }
    }
}
