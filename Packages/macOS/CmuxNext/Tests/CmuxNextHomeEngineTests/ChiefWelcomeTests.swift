import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief's first-launch welcome (#26053): one message from the Chief in its own conversation,
/// once per Chief home, never into a conversation that already has history, and never before the
/// old Chiefs' migration has run.
@Suite struct ChiefWelcomeTests {
    private static let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
    private static let mux = ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "Chief", agentClass: "mux", acpSession: "mux")
    private static let text = ChiefWelcome.text(goTo: "⌘P", shortcuts: [
        ChiefWelcome.Shortcut(keys: "⇧⌘P", title: "Command Palette"),
        ChiefWelcome.Shortcut(keys: "⌘T", title: "New Tab"),
    ])

    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-welcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func summary(_ id: String, lastSeq: UInt64) -> ConversationSummary {
        ConversationSummary(id: id, title: "Chief", participants: [me, mux], lastSeq: lastSeq, rev: 1,
                            createdAt: "2026-10-27T00:00:00.000Z", updatedAt: "2026-10-27T00:00:00.000Z")
    }

    @Test func aFreshChiefHomeGetsOneWelcomeFromTheChiefAndNeverASecond() async throws {
        let root = try home()
        let owner = FakeOwner(listed: [])
        let welcome = ChiefWelcome(root: root, chief: "agent_mux")
        let record = await welcome.run(owner: owner.owner, text: Self.text)
        #expect(record == ChiefWelcome.Record(conversation: "conv_created", seq: 1))
        #expect(await owner.created == 1)
        let request = try #require(await owner.imports.first)
        #expect(request.conversation == "conv_created")
        let message = try #require(request.messages.first)
        #expect(request.messages.count == 1)
        #expect(message.author == "agent_mux")
        #expect(message.clientMsgID == "notice:chief-welcome-v1")
        #expect(message.parts == [.object(["type": .string("text"), "text": .string(Self.text)])])
        // Read for the local user up to the welcome: no unread dot or badge for it.
        #expect(await owner.reads == [ReadMark(conversation: "conv_created", seq: 1)])

        // The next launch reads the record and posts nothing, even while the conversation reads as empty.
        let again = await ChiefWelcome(root: root, chief: "agent_mux").run(owner: owner.owner, text: Self.text)
        #expect(again == record)
        #expect(await owner.imports.count == 1)
        #expect(await ChiefWelcome(root: root, chief: "agent_mux").load() == record)
    }

    @Test func anEmptyChiefConversationGetsTheWelcomeWithoutAnotherCreate() async throws {
        let owner = FakeOwner(listed: [Self.summary("conv_chief", lastSeq: 0)])
        let record = await ChiefWelcome(root: try home(), chief: "agent_mux").run(owner: owner.owner, text: Self.text)
        #expect(record == ChiefWelcome.Record(conversation: "conv_chief", seq: 1))
        #expect(await owner.created == 0)
        #expect(await owner.imports.map(\.conversation) == ["conv_chief"])
    }

    @Test func aChiefConversationWithHistoryIsNeverWelcomed() async throws {
        let root = try home()
        let owner = FakeOwner(listed: [Self.summary("conv_chief", lastSeq: 12)])
        let record = await ChiefWelcome(root: root, chief: "agent_mux").run(owner: owner.owner, text: Self.text)
        #expect(record == ChiefWelcome.Record(conversation: "conv_chief", seq: 0))
        #expect(await owner.imports.isEmpty)
        // Recorded: an upgrade never gets the welcome later, e.g. once the history is gone.
        let emptied = FakeOwner(listed: [Self.summary("conv_chief", lastSeq: 0)])
        _ = await ChiefWelcome(root: root, chief: "agent_mux").run(owner: emptied.owner, text: Self.text)
        #expect(await emptied.imports.isEmpty)
        #expect(record?.isOnlyMessage(of: "conv_chief", lastSeq: 0) == false)
    }

    @Test func anUpgradeWithoutALocalChiefGetsNoNewChiefConversation() async throws {
        // Other conversations and no local Chief (a cloud Chief has the tab, or the local one was
        // deleted): Home never creates the local Chief there, so the welcome does not either.
        let other = ConversationSummary(id: "conv_lane", title: "Lane", participants: [Self.me], lastSeq: 3, rev: 1,
                                        createdAt: "2026-10-27T00:00:00.000Z", updatedAt: "2026-10-27T00:00:00.000Z")
        let root = try home()
        let owner = FakeOwner(listed: [other])
        let record = await ChiefWelcome(root: root, chief: "agent_mux").run(owner: owner.owner, text: Self.text)
        #expect(record == ChiefWelcome.Record(conversation: "", seq: 0))
        #expect(await owner.created == 0)
        #expect(await owner.imports.isEmpty)
        #expect(await ChiefWelcome(root: root, chief: "agent_mux").load() == record)
    }

    @Test func aFailedImportRecordsNothingAndTheNextConnectionPosts() async throws {
        let root = try home()
        let failing = FakeOwner(listed: [Self.summary("conv_chief", lastSeq: 0)], fails: true)
        #expect(await ChiefWelcome(root: root, chief: "agent_mux").run(owner: failing.owner, text: Self.text) == nil)
        #expect(await ChiefWelcome(root: root, chief: "agent_mux").load() == nil)

        let working = FakeOwner(listed: [Self.summary("conv_chief", lastSeq: 0)])
        #expect(await ChiefWelcome(root: root, chief: "agent_mux").run(owner: working.owner, text: Self.text)
            == ChiefWelcome.Record(conversation: "conv_chief", seq: 1))
    }

    @Test func aWelcomeAnEarlierLaunchPostedWithoutItsRecordIsStillTheWelcome() async throws {
        // The import landed but its reply or the record's write did not: the next launch lists the
        // welcome as the only message and records it, never as history and never posting again.
        var summary = Self.summary("conv_chief", lastSeq: 1)
        summary.lastMessage = ConversationMessage(id: "msg_1", conversation: "conv_chief", seq: 1, clientMsgID: ChiefWelcome.clientMsgID,
                                                  author: "agent_mux", parts: [], createdAt: "2026-10-27T00:00:00.000Z")
        let owner = FakeOwner(listed: [summary])
        let record = await ChiefWelcome(root: try home(), chief: "agent_mux").run(owner: owner.owner, text: Self.text)
        #expect(record == ChiefWelcome.Record(conversation: "conv_chief", seq: 1))
        #expect(await owner.imports.isEmpty)
        #expect(await owner.reads == [ReadMark(conversation: "conv_chief", seq: 1)])
    }

    @Test func aRaceTheOwnerSkippedIsRecordedAsTheFirstMessage() async throws {
        // Two launches raced on an empty conversation: the owner skips the second import.
        let owner = FakeOwner(listed: [Self.summary("conv_chief", lastSeq: 0)], imported: [])
        let record = await ChiefWelcome(root: try home(), chief: "agent_mux").run(owner: owner.owner, text: Self.text)
        #expect(record == ChiefWelcome.Record(conversation: "conv_chief", seq: 1))
    }

    @Test func onNightlyItWaitsForTheOldChiefsMigration() async throws {
        let root = try home()
        let owner = FakeOwner(listed: [])
        let welcome = ChiefWelcome(root: root, chief: "agent_mux", waitsForMigration: true)
        // Blocked or not yet run: a welcome now would put the migration's older messages out of order.
        #expect(await welcome.run(owner: owner.owner, text: Self.text) == nil)
        #expect(await owner.imports.isEmpty)
        try Data("{}".utf8).write(to: root.appendingPathComponent(ChiefMigration.recordName))
        #expect(await welcome.run(owner: owner.owner, text: Self.text) == ChiefWelcome.Record(conversation: "conv_created", seq: 1))
    }

    @Test func homeTreatsAConversationWithOnlyTheWelcomeAsEmpty() {
        let record = ChiefWelcome.Record(conversation: "conv_chief", seq: 1)
        #expect(record.isOnlyMessage(of: "conv_chief", lastSeq: 1))
        #expect(!record.isOnlyMessage(of: "conv_chief", lastSeq: 2), "the person's first message is history")
        #expect(!record.isOnlyMessage(of: "conv_other", lastSeq: 1))
    }

    @Test func theTextCallsOutCommandPFirstThenTheShortcutsExamplesAndWhatToAsk() throws {
        let text = Self.text
        let goTo = try #require(text.range(of: HomeStrings.chiefWelcomeGoTo("⌘P")))
        let palette = try #require(text.range(of: "- `⇧⌘P` Command Palette"))
        let newTab = try #require(text.range(of: "- `⌘T` New Tab"))
        let examples = try #require(text.range(of: HomeStrings.chiefWelcomeExamplesHeader))
        let ask = try #require(text.range(of: HomeStrings.chiefWelcomeAsk))
        #expect(text.hasPrefix(HomeStrings.chiefWelcomeIntro))
        #expect(goTo.lowerBound < palette.lowerBound && palette.lowerBound < newTab.lowerBound)
        #expect(newTab.lowerBound < examples.lowerBound && examples.lowerBound < ask.lowerBound)
        #expect(HomeStrings.chiefWelcomeAsk.contains("coding agents") && HomeStrings.chiefWelcomeAsk.contains("browsers"))
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count == 2 + 4)

        // An unbound Go to Workspace drops the call-out, never shows an empty key.
        let unbound = ChiefWelcome.text(goTo: nil, shortcuts: [])
        #expect(!unbound.contains("**"))
        #expect(!unbound.contains(HomeStrings.chiefWelcomeShortcuts))
    }

    @Test func theTimeIsTheOwnersFormatAndNeverInItsFuture() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000.5)
        let stamp = ChiefWelcome.timestamp(now)
        // conversation_import.rs `valid_time`: YYYY-MM-DDTHH:MM:SS.mmmZ.
        #expect(stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try #require(formatter.date(from: stamp))
        #expect(parsed < now)
    }
}

private struct ReadMark: Equatable {
    var conversation: String
    var seq: UInt64
}

/// A Chief owner: its list, the creates and imports it received; `fails` refuses every import.
private actor FakeOwner {
    let listed: [ConversationSummary]
    let fails: Bool
    let imported: [UInt64]
    var created = 0
    var imports: [ConversationImportRequest] = []
    var reads: [ReadMark] = []

    init(listed: [ConversationSummary], fails: Bool = false, imported: [UInt64] = [1]) {
        self.listed = listed
        self.fails = fails
        self.imported = imported
    }

    nonisolated var owner: ChiefWelcome.Owner {
        ChiefWelcome.Owner(list: { self.listed }, create: { await self.create() }, importMessages: { try await self.receive($0) },
                           markRead: { await self.read($0, $1) })
    }

    func read(_ conversation: String, _ seq: UInt64) {
        reads.append(ReadMark(conversation: conversation, seq: seq))
    }

    func create() -> String {
        created += 1
        return "conv_created"
    }

    func receive(_ request: ConversationImportRequest) throws -> [UInt64] {
        if fails { throw DaemonError.notConnected }
        imports.append(request)
        return imported
    }
}
