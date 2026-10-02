import CmuxNextDaemon
import Testing
@testable import CmuxNextApp

@MainActor @Suite struct HomeMentionsTests {
    private let mux = ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "mux", agentClass: "mux")
    private let austin = ConversationParticipant(id: "user_austin", kind: .human, displayName: "Austin")

    @Test func mentionsBecomeRunsNamingTheParticipant() {
        let runs = HomeMentions.runs(in: "hey @mux and @austin, look", participants: [mux, austin])
        #expect(runs == [ConversationTextRun(start: 4, length: 4, mention: "agent_mux"),
                         ConversationTextRun(start: 13, length: 7, mention: "user_austin")])
    }

    @Test func partialWordsAndEmailsAreNotMentions() {
        #expect(HomeMentions.runs(in: "me@mux.dev", participants: [mux]).isEmpty)
        #expect(HomeMentions.runs(in: "@muxer", participants: [mux]).isEmpty)
        #expect(HomeMentions.runs(in: "@nobody", participants: [mux]).isEmpty)
    }

    @Test func offsetsAreUTF16() {
        let runs = HomeMentions.runs(in: "👋 @mux", participants: [mux])
        #expect(runs == [ConversationTextRun(start: 3, length: 4, mention: "agent_mux")])
    }
}
