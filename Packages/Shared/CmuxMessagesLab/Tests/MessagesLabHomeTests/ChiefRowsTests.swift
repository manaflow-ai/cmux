import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief's tool calls and approvals as hosted rows (Cmux/ChiefRows.swift): runs of
/// tool calls fold into their first message, tool rows draw as their own sender, an
/// approval is a custom card, and HomeStore changes reach the rows as `.setCustomPart`.
@MainActor @Suite struct ChiefRowsTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_rows")
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static var summary: ConversationSummary {
        ConversationSummary(id: id, title: "Chief",
                            participants: [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                                           CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)],
                            lastSeq: 10, createdAt: base, updatedAt: base)
    }

    static func item(_ seq: Seq, _ parts: [MessagePart], by author: ParticipantID = ParticipantID("agent_chief")) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: seq, author: author, parts: parts,
                       createdAt: base.addingTimeInterval(Double(seq)), delivery: .committed, messageID: MessageID("m\(seq)"))
    }

    static func work(_ id: String, _ title: String, _ status: WorkRef.Status = .running) -> MessagePart {
        .work(WorkRef(session: id, title: title, status: status, preview: title))
    }

    static func message(_ item: TranscriptItem, in items: [TranscriptItem]) -> MessagesLabHome.Message {
        let roles = ChiefRows.roles(items)
        return HomeMapping.message(item, aliases: [:], me: me, summary: summary, role: roles.value(for: item.key) ?? .other)
    }

    static func tools(_ part: Part?) -> ChiefRows.Tools? {
        guard case let .custom(c)? = part, c.kind == ChiefRows.toolKind else { return nil }
        return c.decode(ChiefRows.Tools.self)
    }

    @Test func consecutiveToolCallsFoldIntoTheirFirstMessage() {
        let items = [
            Self.item(1, [.text("How many workspaces?")], by: Self.me),
            Self.item(2, [Self.work("t1", "cmux tree --all", .done)]),
            Self.item(3, [Self.work("t2", "cmux list-workspaces", .done)]),
            Self.item(4, [Self.work("t3", "git status")]),
            Self.item(5, [.text("You have 3.")]),
            Self.item(6, [Self.work("t4", "Read README.md")]),
        ]
        let head = Self.message(items[1], in: items)
        let run = Self.tools(head.parts.first)
        #expect(head.parts.count == 1)
        #expect(run?.calls.map(\.title) == ["cmux tree --all", "cmux list-workspaces", "git status"])
        #expect(run?.state == .running)
        #expect(ChiefRows.summary(run!) == "Ran 3 commands")
        // The later calls of the run show nothing; their messages stay (the window count).
        #expect(Self.message(items[2], in: items).parts.isEmpty)
        #expect(Self.message(items[3], in: items).parts.isEmpty)
        // Text ends the run: the next call is a row of its own.
        #expect(Self.tools(Self.message(items[5], in: items).parts.first)?.calls.count == 1)
        // Tool rows are another sender, so the Chief's bubbles around them group on their own.
        #expect(head.senderId == ChiefRows.toolSender(Self.chief))
        #expect(Self.message(items[4], in: items).senderId == Self.chief.rawValue)
        #expect(HomeMapping.participants(Self.summary, me: Self.me).contains { $0.id == ChiefRows.toolSender(Self.chief) && $0.displayName == "Chief" })
    }

    @Test func aFinishedCallUpdatesItsRowInPlace() {
        let before = [Self.item(1, [Self.work("t1", "cmux tree --all")]), Self.item(2, [Self.work("t2", "git status")])]
        var after = before
        after[1] = Self.item(2, [Self.work("t2", "git status", .done)])
        let d = HomeDiff.plan(old: before, new: after, oldSummary: Self.summary, newSummary: Self.summary, aliases: [:], me: Self.me)
        #expect(!d.rebuild)
        #expect(d.actions.count == 1)
        guard case let .setCustomPart(id, pi, part)? = d.actions.first else { Issue.record("no setCustomPart"); return }
        #expect(id == "k1")
        #expect(pi == 0)
        #expect(part.decode(ChiefRows.Tools.self)?.calls.last?.state == .done)
    }

    @Test func aNewCallGrowsTheRunAndArrivesFolded() {
        let before = [Self.item(1, [Self.work("t1", "cmux tree --all", .done)])]
        let after = before + [Self.item(2, [Self.work("t2", "git status")])]
        let d = HomeDiff.plan(old: before, new: after, oldSummary: Self.summary, newSummary: Self.summary, aliases: [:], me: Self.me)
        #expect(!d.rebuild)
        #expect(d.actions.map(HomeDiff.describe).count == 2)
        guard case let .setCustomPart(id, _, part)? = d.actions.first else { Issue.record("no setCustomPart"); return }
        #expect(id == "k1")
        #expect(part.decode(ChiefRows.Tools.self)?.calls.count == 2)
        guard case let .receive(m)? = d.actions.last else { Issue.record("no receive"); return }
        #expect(m.parts.isEmpty)
    }

    @Test func approvalsAreCardsThatTurnIntoReceipts() {
        let pending = Self.item(1, [.approval(ApprovalRef(request: "perm-1", prompt: "Run `cmux tree --all 2>&1 | head`?",
                                                         options: ["Allow", "Deny"]))])
        let m = HomeMapping.message(pending, aliases: [:], me: Self.me, summary: Self.summary)
        guard case let .custom(c)? = m.parts.first, let card = c.decode(ChiefRows.Approval.self) else {
            Issue.record("no approval card"); return
        }
        #expect(c.kind == ChiefRows.approvalKind)
        #expect(card.agent == "Chief")
        #expect(card.command == "cmux tree --all 2>&1 | head")
        #expect(card.prominent == "Allow")
        #expect(card.refusal == "Deny")
        #expect(card.buttonOrder == ["Deny", "Allow"])
        #expect(card.alwaysAllowPrefix == nil) // a pipeline gets no rule
        #expect(ChiefRows.caption(card) == "Chief wants to run")
        #expect(m.senderId == ChiefRows.toolSender(Self.chief))

        let decided = Self.item(1, [.approval(ApprovalRef(request: "perm-1", prompt: "Run `cmux tree --all 2>&1 | head`?",
                                                         options: ["Allow", "Deny"], decided: "Allow"))])
        let d = HomeDiff.plan(old: [pending], new: [decided], oldSummary: Self.summary, newSummary: Self.summary, aliases: [:], me: Self.me)
        #expect(!d.rebuild)
        guard case let .setCustomPart(_, _, part)? = d.actions.first,
              let answered = part.decode(ChiefRows.Approval.self) else { Issue.record("no setCustomPart"); return }
        #expect(answered.decided == "Allow")
        #expect(ChiefRows.decidedLabel("Allow", command: answered.command) == "Allowed: cmux tree --all 2>&1 | head")
        #expect(ChiefRows.decidedLabel("Deny", command: answered.command) == "Denied")
    }

    /// A card an earlier run left open is settled "expired" by the owner (ChiefConversationOwner.approvalExpired).
    @Test func anExpiredCardReadsExpiredNotAChoice() {
        #expect(ChiefRows.decidedLabel("expired") == "Expired")
        #expect(ChiefRows.decidedLabel("expired", command: "ls") == "Expired")
    }

    /// The owner stores tool titles and prompts in canonical English; Home draws them in the user's language.
    @Test func canonicalTitlesAndPromptsReadThroughTheCatalog() {
        #expect(ChiefRows.displayTitle("Read Sources/App.swift") == "Read Sources/App.swift")
        #expect(ChiefRows.displayTitle("Search the web: swift actors") == "Search the web: swift actors")
        #expect(ChiefRows.displayTitle("Find tools") == "Find tools")
        #expect(ChiefRows.displayTitle("List workspaces") == "List workspaces")
        #expect(ChiefRows.displayPrompt("Run `cmux tree`?") == "Run `cmux tree`?")
        #expect(ChiefRows.displayPrompt("Allow Edit README.md?") == "Allow Edit README.md?")
        #expect(ChiefRows.displayPrompt("Approve the plan?") == "Approve the plan?")
        #expect(ChiefRows.ToolKind(title: "Read a.swift").localizedFrame("a.swift") == "Read a.swift")
        #expect(ChiefRows.ToolKind(title: "cmux tree --all").localizedFrame("x") == nil)
    }

    @Test func approvalAnswersTravelAsQuestionSelections() {
        let answer = ChiefApprovalAnswer.answer(choice: "Allow", always: true)
        #expect(answer.selections[ChiefApprovalAnswer.item]?.optionIDs == ["Allow"])
        #expect(answer.selections[ChiefApprovalAnswer.always] != nil)
        #expect(ChiefApprovalAnswer.answer(choice: "Deny").selections[ChiefApprovalAnswer.always] == nil)
    }

    @Test func toolKindsPickTheirGlyphAndCode() {
        #expect(ChiefRows.ToolKind(title: "cmux tree --all") == .command)
        #expect(ChiefRows.ToolKind(title: "List workspaces") == .described)
        #expect(ChiefRows.ToolKind(title: "Read Sources/App.swift").symbol == "doc.text")
        #expect(ChiefRows.ToolKind(title: "Edit Sources/App.swift").symbol == "pencil")
        #expect(ChiefRows.ToolKind(title: "Search TODO").symbol == "magnifyingglass")
        #expect(ChiefRows.ToolKind(title: "Fetch https://example.com").symbol == "globe")
        #expect(ChiefRows.ToolKind(title: "Read a.swift").split("Read a.swift") == ("Read ", "a.swift"))
        #expect(ChiefRows.lineText(ChiefRows.ToolCall(id: "1", title: "cmux tree", state: .done)) == "Ran cmux tree")
        #expect(ChiefRows.lineText(ChiefRows.ToolCall(id: "1", title: "cmux tree", state: .running)) == "Running cmux tree")
        #expect(ChiefToolRowView.truncated(Array("abc defghij"), keep: 6) == "abc…")
    }

    @Test func promptsAndRules() {
        #expect(ChiefRows.promptRuns("Run `ls -la`?").map(\.0) == ["Run ", "ls -la", "?"])
        #expect(ChiefRows.promptRuns("Run `ls -la`?").map(\.1) == [false, true, false])
        #expect(ChiefRows.promptRuns("a `b").map(\.1) == [false, false])
        #expect(ChiefRows.command(inPrompt: "Allow Edit a.swift?") == nil)
    }

    /// The card offers the rule the owner put in its options (ChiefAllowRules.cardOptions in
    /// CmuxChief, from lexed words), whatever quotes the command has, and never shows it as a button.
    @Test func alwaysAllowReadsTheOwnersRule() {
        let dispatch = ##"cmux chief dispatch --agent codex --name "#123: fix login" --cwd /tmp/app --wait-working --json -- 'Fix it.'"##
        let ref = ApprovalRef(request: "perm-1", prompt: "Run `\(dispatch)`?",
                              options: ["Allow", "Deny", "always:cmux chief dispatch"])
        let card = ChiefRows.Approval(ref, agent: "Chief")
        #expect(card.alwaysAllowPrefix == "cmux chief dispatch")
        #expect(card.options == ["Allow", "Deny"])
        #expect(card.buttonOrder == ["Deny", "Allow"])
        #expect(card.command == dispatch)
        // The rule survives the part's encoding.
        let part = ChiefRows.part(kind: ChiefRows.approvalKind, card)
        #expect(part.decode(ChiefRows.Approval.self)?.alwaysAllowPrefix == "cmux chief dispatch")
        // No rule option: no menu, even for a plain command.
        let plain = ChiefRows.Approval(ApprovalRef(request: "perm-2", prompt: "Run `cmux tree --all`?", options: ["Allow", "Deny"]))
        #expect(plain.alwaysAllowPrefix == nil)
        // A card with nothing that grants offers no rule.
        let noGrant = ChiefRows.Approval(ApprovalRef(request: "perm-3", prompt: "Run `cmux tree`?",
                                                     options: ["Deny", "always:cmux tree"]))
        #expect(noGrant.alwaysAllowPrefix == nil)
    }

    @Test func aHostedWorkPartIsNeverFolded() {
        let card = MessagePart.work(WorkRef(session: "ws", host: "brave-otter", title: "Ready", status: .done))
        let items = [Self.item(1, [Self.work("t1", "cmux tree")]), Self.item(2, [card])]
        #expect(ChiefRows.roles(items).value(for: IdempotencyKey("k2")) == nil)
        // It is a row of its own: the Cloud result card (ChiefCloudRows), not a tool row.
        let shown = Self.message(items[1], in: items).parts
        #expect(shown.count == 1)
        guard case let .custom(c)? = shown.first else { Issue.record("no custom part: \(shown)"); return }
        #expect(c.kind == ChiefCloudRows.resultKind)
        #expect(c.decode(ChiefCloudRows.Result.self)?.title == "Ready")
        #expect(c.decode(ChiefCloudRows.Result.self)?.machine == "brave-otter")
    }
}
