import Foundation
import Testing
@testable import CmuxHomeCore

/// An inbox refetch that brings the inbox the mirror already has is no new information: it must
/// not move the mirror's cache change count, or the store schedules a Home cache write for it
/// (speed-of-sound-DESIGN.md 3.5). Before, `apply(inbox:)` assigned `me`, `conversations` and
/// `windows` on every refetch, so each refetch rewrote the cache with the same content.
@Suite struct HomeMirrorEqualInboxTests {
    static let austin = ConversationID("conv_austin")
    static let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    static let chief = Participant(id: ParticipantID("agent_chief"), kind: .agent, displayName: "Chief", agentClass: .chief)

    static func inbox(rev: Revision, conversations: [ConversationID] = [austin]) -> InboxSnapshot {
        let summaries = conversations.map { id in
            ConversationSummary(id: id, participants: [me, chief], lastSeq: 0, rev: 1,
                                createdAt: Date(timeIntervalSince1970: 0),
                                updatedAt: Date(timeIntervalSince1970: 0), pinRank: nil)
        }
        return InboxSnapshot(me: me, conversations: summaries, rev: rev)
    }

    @Test func theSameInboxAgainMovesNoCacheChange() {
        var mirror = HomeMirror()
        mirror.apply(inbox: Self.inbox(rev: 1))
        mirror.beginLoading(Self.austin)
        let before = mirror.cacheChanges.value
        for rev in 2...6 { mirror.apply(inbox: Self.inbox(rev: Revision(rev))) }
        #expect(mirror.cacheChanges.value == before, "an equal inbox moved the cache change count")
        #expect(mirror.revision(of: .inbox) == 6, "the inbox revision still follows the owner")
    }

    @Test func aChangedInboxStillMovesTheCacheChange() {
        var mirror = HomeMirror()
        mirror.apply(inbox: Self.inbox(rev: 1))
        mirror.beginLoading(Self.austin)
        let before = mirror.cacheChanges.value
        mirror.apply(inbox: Self.inbox(rev: 2, conversations: []))
        #expect(mirror.cacheChanges.value != before, "a conversation that left the inbox is new information")
        #expect(mirror.windows[Self.austin] == nil)
    }
}
