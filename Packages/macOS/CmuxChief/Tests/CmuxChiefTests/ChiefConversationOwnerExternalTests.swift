import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

@Suite struct ChiefConversationOwnerExternalTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    @Test func participantIDIsStablePerName() {
        #expect(ChiefConversationOwner.externalParticipantID(for: "Build Bot")?.rawValue == "agent_ext_build-bot")
        #expect(ChiefConversationOwner.externalParticipantID(for: "  build   BOT! ") == ChiefConversationOwner.externalParticipantID(for: "Build Bot"))
        #expect(ChiefConversationOwner.externalParticipantID(for: "   ") == nil)
        let unicode = ChiefConversationOwner.externalParticipantID(for: "ビルド")
        #expect(unicode != nil)
        #expect(unicode == ChiefConversationOwner.externalParticipantID(for: "ビルド"))
        #expect(unicode?.rawValue.hasPrefix("agent_ext_h") == true)
    }

    @Test func reportWithoutTurnAddsAgentParticipantAndCommits() async throws {
        let brain = FakeBrain.replying(["unused"])
        let owner = try ChiefFixture().owner(brain)
        let recorder = EventRecorder()
        await recorder.start(owner)
        let id = try await owner.postExternal(conversation: nil, from: "Build Bot", text: "  tests green  ", startTurn: false)
        let page = try await owner.snapshot(of: conversation, tail: 10)
        let message = try #require(page.messages.last)
        #expect(message.id == id)
        #expect(message.plainText == "tests green")
        let author = try #require(page.conversation.participants.first { $0.id == message.author })
        #expect(author.kind == .agent)
        #expect(author.agentClass == .agent)
        #expect(author.displayName == "Build Bot")
        #expect(!author.isChief)
        #expect(await ChiefFixture.eventually { await recorder.messages().contains { $0.id == id } })
        #expect(await owner.isWorking(conversation) == false)
        #expect(await brain.log.requests.isEmpty)

        // A second report reuses the participant.
        _ = try await owner.postExternal(conversation: conversation, from: "build bot", text: "deployed", startTurn: false)
        let after = try await owner.snapshot(of: conversation, tail: 10)
        #expect(after.conversation.participants.filter { $0.id == author.id }.count == 1)
        #expect(after.messages.count == 2)
    }

    @Test func reportWithTurnStartsChiefTurnWithPrefixedText() async throws {
        let brain = FakeBrain.replying(["Noted."])
        let owner = try ChiefFixture().owner(brain)
        _ = try await owner.postExternal(conversation: nil, from: "Codex", text: "PR #12 is ready", startTurn: true)
        let messages = try await ChiefFixture.idleMessages(owner, count: 2)
        #expect(messages.map(\.plainText) == ["PR #12 is ready", "Noted."])
        #expect(messages[1].author == ChiefConversationOwner.chiefID)
        let requests = await brain.log.requests
        #expect(requests.map(\.userText) == ["[report from Codex] PR #12 is ready"])
    }

    @Test func rejectsBadInput() async throws {
        let owner = try ChiefFixture().owner(.replying(["x"]))
        await #expect(throws: HomeRejection.self) {
            try await owner.postExternal(conversation: nil, from: "  ", text: "hi", startTurn: false)
        }
        await #expect(throws: HomeRejection.self) {
            try await owner.postExternal(conversation: nil, from: "Bot", text: "   ", startTurn: false)
        }
        await #expect(throws: HomeRejection.self) {
            try await owner.postExternal(conversation: ConversationID("conv_missing"), from: "Bot", text: "hi", startTurn: false)
        }
    }

    @Test func transcriptNamesAuthorsOldestFirst() async throws {
        let owner = try ChiefFixture().owner(.replying(["Hello there"]))
        try await ChiefFixture.send("hi Chief", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        _ = try await owner.postExternal(conversation: nil, from: "Bot", text: "done", startTurn: false)
        let all = try await owner.transcriptText(conversation: nil, limit: 10)
        #expect(all == "Tester: hi Chief\nChief: Hello there\nBot: done")
        let tail = try await owner.transcriptText(conversation: conversation, limit: 1)
        #expect(tail == "Bot: done")
    }
}
