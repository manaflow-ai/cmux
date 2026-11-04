import CmuxAgentQuestion
@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// Damaged conversation files, approvals across turns and runs, the
/// background load and the package's localized text.
@Suite struct ChiefConversationRecoveryTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    private static func file(_ fixture: ChiefFixture, _ name: String = "conv_chief") -> URL {
        fixture.home.conversationsDirectory.appendingPathComponent("\(name).jsonl")
    }

    private static func asideFiles(_ fixture: ChiefFixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.home.conversationsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    private static func answer(_ choice: String) -> AgentQuestionAnswer {
        AgentQuestionAnswer(selections: [ChiefConversationOwner.approvalAnswerItem: AgentQuestionAnswer.Selection(optionIDs: [choice])])
    }

    // MARK: Damaged files

    @Test func aDamagedLineBeforeTheLastKeepsTheOriginalAndTheRest() async throws {
        let fixture = ChiefFixture()
        let first = try fixture.owner(.replying(["Remembered"]))
        try await ChiefFixture.send("remember me", to: first)
        _ = try await ChiefFixture.idleMessages(first, count: 2)
        await first.shutdown()

        // A bad line in the middle (not a crash's partial last line).
        let file = Self.file(fixture)
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.insert("{\"message\":{\"_0\":{\"broken\"", at: 1)
        let damaged = lines.joined(separator: "\n") + "\n"
        try damaged.write(to: file, atomically: true, encoding: .utf8)

        let second = try fixture.owner(.replying([]))
        #expect(try await second.snapshot(of: conversation, tail: 10).messages.map(\.plainText) == ["remember me", "Remembered"])
        let aside = try Self.asideFiles(fixture)
        #expect(aside.count == 1)
        #expect(try aside.first.map { try String(contentsOf: $0, encoding: .utf8) } == damaged)
        #expect(!second.loadProblems.isEmpty)
        // The kept file is never read as a conversation.
        let third = try fixture.owner(.replying([]))
        #expect(await third.inbox().conversations.count == 1)
    }

    @Test func aFileWithNoSummaryIsKeptAsideNotOverwritten() async throws {
        let fixture = ChiefFixture()
        try fixture.home.createDirectories()
        let garbage = "not a record\nnor this\n"
        try garbage.write(to: Self.file(fixture), atomically: true, encoding: .utf8)

        let owner = try fixture.owner(.replying([]))
        // The default conversation is available, and the unreadable bytes survive next to it.
        #expect(await owner.inbox().conversations.map(\.id) == [conversation])
        let aside = try Self.asideFiles(fixture)
        #expect(try aside.map { try String(contentsOf: $0, encoding: .utf8) } == [garbage])
    }

    @Test func anUnreadableFileDoesNotDisableChief() async throws {
        let fixture = ChiefFixture()
        try fixture.home.createDirectories()
        // A directory named like a conversation file: reading it fails.
        try FileManager.default.createDirectory(at: Self.file(fixture, "conv_other"), withIntermediateDirectories: true)

        let owner = try fixture.owner(.replying(["Still here"]))
        try await ChiefFixture.send("hello", to: owner)
        #expect(try await ChiefFixture.idleMessages(owner, count: 2).map(\.plainText) == ["hello", "Still here"])
        #expect(owner.loadProblems.contains { $0.contains("conv_other.jsonl") })
    }

    @Test func pagesFindMessagesBySeqAcrossAGap() {
        let summary = ConversationSummary(id: conversation, owner: .local, participants: [], createdAt: Date(), updatedAt: Date())
        let messages = [1, 2, 4, 5].map { seq in
            Message(id: MessageID("msg_\(seq)"), conversation: conversation, seq: Seq(seq), clientMessageID: .make(),
                    author: ChiefConversationOwner.userID, parts: [.text("m\(seq)")], createdAt: Date())
        }
        let state = ChiefConversationState(summary: summary, messages: messages)
        #expect(state.messages(from: 4, through: 5).map(\.seq) == [4, 5])
        #expect(state.messages(from: 2, through: 4).map(\.seq) == [2, 4])
        #expect(state.messages(from: 3, through: 3).isEmpty)
        #expect(state.messages(from: 1, through: 100).map(\.seq) == [1, 2, 4, 5])
    }

    // MARK: Approvals

    /// A brain that asks approval `perm-1` every turn (as a restarted Codex numbers its requests again).
    private static func repeatingBrain(_ gate: Gate) -> FakeBrain {
        FakeBrain { _, continuation in
            continuation.yield(.approvalRequested(id: "perm-1", prompt: "Run `ls`?", options: ["Allow", "Deny"]))
            await gate.wait()
            continuation.finish()
        }
    }

    @Test func anOldCardCannotDecideANewTurnsRequestWithTheSameID() async throws {
        let gate = Gate()
        let brain = Self.repeatingBrain(gate)
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("first", to: owner)
        #expect(await ChiefFixture.eventually { await owner.isWaitingForApproval(conversation) })
        let oldCard = try #require(await owner.pendingApproval(in: conversation))
        #expect(await owner.stopTurn(conversation: conversation))

        try await ChiefFixture.send("second", to: owner)
        #expect(await ChiefFixture.eventually {
            await owner.pendingApproval(in: conversation).map { $0.message != oldCard.message } ?? false
        })
        let newCard = try #require(await owner.pendingApproval(in: conversation))
        #expect(newCard.request != oldCard.request)

        // Answering the old (settled) card is refused and leaves the new one waiting.
        await #expect(throws: HomeRejection.invalid("approval_decided")) {
            try await owner.submit(HomeIntent(op: .answerQuestion(message: oldCard.message, conversation: self.conversation,
                                                                  partIndex: oldCard.part, answer: Self.answer("Allow"))))
        }
        #expect(await owner.pendingApproval(in: conversation)?.ref.decided == nil)
        #expect(await owner.pendingApproval(in: conversation)?.message == newCard.message)

        try await owner.answerApproval(conversation: conversation, message: newCard.message, part: newCard.part, choice: "Allow")
        #expect(await brain.log.approvals.map { "\($0.id):\($0.choice)" } == ["perm-1:Allow"])
        await gate.open()
    }

    @Test func cardsAndWorkLeftOpenByAnEarlierRunSettleOnLoad() async throws {
        let gate = Gate()
        let fixture = ChiefFixture()
        let brain = FakeBrain { _, continuation in
            continuation.yield(.toolStarted(id: "t1", title: "Read notes.md", detail: nil))
            continuation.yield(.approvalRequested(id: "perm-1", prompt: "Run `ls`?", options: ["Allow", "Deny"]))
            await gate.wait()
            continuation.finish()
        }
        let first = try fixture.owner(brain)
        try await ChiefFixture.send("look around", to: first)
        #expect(await ChiefFixture.eventually { await first.isWaitingForApproval(conversation) })
        // The app quits without ending the turn: the file still has the open card and the running row.

        let second = try fixture.owner(.replying([]))
        let messages = try await second.snapshot(of: conversation, tail: 10).messages
        let approvals = messages.flatMap(\.parts).compactMap { part -> ApprovalRef? in
            if case .approval(let ref) = part { return ref }
            return nil
        }
        let work = messages.flatMap(\.parts).compactMap { part -> WorkRef? in
            if case .work(let ref) = part { return ref }
            return nil
        }
        #expect(approvals.map(\.decided) == [ChiefConversationOwner.approvalExpired])
        #expect(work.map(\.status) == [.failed])
        // `chief.approve` without an id finds nothing: no turn of this run waits.
        #expect(await second.pendingApproval(in: conversation) == nil)
        let card = try #require(messages.first { $0.parts.contains { if case .approval = $0 { true } else { false } } })
        await #expect(throws: HomeRejection.invalid("approval_decided")) {
            try await second.answerApproval(conversation: self.conversation, message: card.id, part: 0, choice: "Allow")
        }
        await gate.open()
        await first.shutdown()
    }

    // MARK: Background load

    @Test func aSourceOverALoadingOwnerConnectsWhenTheLoadEnds() async throws {
        let fixture = ChiefFixture()
        let home = fixture.home
        let gate = Gate()
        let loading = Task<ChiefConversationOwner, any Error> {
            await gate.wait()
            return try await ChiefConversationOwner.load(home: home, brain: FakeBrain.replying([]), userDisplayName: "Tester") { _ in
                ChiefTurnContext(systemPrompt: "", workingDirectory: home.root, environment: [:])
            }
        }
        let source = ChiefLocalSource(loading: loading)
        let events = Task { () -> HomeEvent? in
            for await event in await source.events() { return event }
            return nil
        }
        await gate.open()
        guard case .connection(.online)? = await events.value else { Issue.record("not online"); return }
        #expect(try await source.inbox().conversations.map(\.id) == [conversation])
    }

    @Test func aSourceOverAFailedLoadIsOffline() async throws {
        let source = ChiefLocalSource(loading: Task<ChiefConversationOwner, any Error> { throw CocoaError(.fileWriteNoPermission) })
        var first: HomeEvent?
        for await event in await source.events() {
            first = event
            break
        }
        guard case .connection(.offline)? = first else { Issue.record("not offline"); return }
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.inbox() }
    }

    // MARK: Localized text

    @Test func transcriptTextIsLocalized() throws {
        // SwiftPM uses both a flat resource directory and an app-style
        // Contents/Resources wrapper across its package and Xcode runners.
        // Read the catalog file directly so the test checks the resource that
        // ships instead of relying on Bundle(path:) accepting an .lproj URL.
        let roots = [ChiefText.bundle.resourceURL, ChiefText.bundle.bundleURL].compactMap { $0 }
        let candidates = roots.flatMap { root in
            [root.appendingPathComponent("ja.lproj/Localizable.strings"),
             root.appendingPathComponent("Contents/Resources/ja.lproj/Localizable.strings")]
        }
        let stringsURL = try #require(candidates.first { FileManager.default.isReadableFile(atPath: $0.path) })
        let strings = try #require(NSDictionary(contentsOf: stringsURL) as? [String: String])
        let failed = try #require(strings["chief.turn.failed"])
        #expect(failed != "chief.turn.failed")
        #expect(failed.contains("%@") && !failed.contains("could not finish"))
        #expect(ChiefText.turnFailed("boom").contains("boom"))
    }
}
