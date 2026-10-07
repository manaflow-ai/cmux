import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// N1: the chief conversation is "Chief" everywhere: its title, the mux's
/// name and avatar, and its tab. A chief conversation made before the name
/// keeps its id and is renamed once through the normal write path.
@MainActor @Suite struct HomeChiefNameTests {
    static let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")

    static func summary(title: String, mux: ConversationParticipant = HomeService.mux) -> CmuxNextDaemon.ConversationSummary {
        CmuxNextDaemon.ConversationSummary(id: "conv_chief", title: title, participants: [me, mux], lastSeq: 0, rev: 1,
                                           createdAt: "2026-10-02T12:00:00.000Z", updatedAt: "2026-10-02T12:00:00.000Z",
                                           lastMessage: nil, readCursors: [:])
    }

    @Test func aNewChiefConversationIsNamedChief() {
        let request = HomeChiefName.createRequest(user: Self.me, mux: HomeService.mux)
        #expect(request.title == "Chief")
        #expect(HomeService.mux.displayName == "Chief")
    }

    /// A conversation made before the name still says "mux": shown as the Chief, avatar C.
    @Test func theMuxShowsAsTheChiefWhateverItsRecordedName() {
        let old = ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "mux", agentClass: "mux", acpSession: "mux")
        let mapped = HomeCoreMapping.participant(old)
        #expect(mapped.displayName == "Chief")
        #expect(mapped.initials == "C")
    }

    @Test func aChiefConversationWithTheOldDefaultTitleIsRenamedOnce() throws {
        let request = try #require(HomeChiefName.migration(for: Self.summary(title: "Home")))
        #expect(request.conversation == "conv_chief")
        #expect(request.idempotencyKey == HomeChiefName.renameKey)
        #expect(request.op == .setTitle("Chief"))
    }

    @Test func aRenamedOrCustomTitledChiefConversationIsLeftAlone() {
        #expect(HomeChiefName.migration(for: Self.summary(title: "Chief")) == nil)
        #expect(HomeChiefName.migration(for: Self.summary(title: "Release plan")) == nil)
    }
}
