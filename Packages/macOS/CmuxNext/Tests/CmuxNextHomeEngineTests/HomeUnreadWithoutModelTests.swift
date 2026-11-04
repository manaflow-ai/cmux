import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// REOPEN-F7 (launch stalls, feat 287ad03, 20 warm reopens): the Dock badge's first count, in the turn after the first
/// window's commit, built the whole Home sidebar model (each row's time string, people, avatars) only to read which
/// conversations are unread. The unread conversations come from the rows, the pins and the marks: reading them asks
/// for none of the list's display inputs, and gives what the list dots, in its order.
@MainActor
@Suite struct HomeUnreadWithoutModelTests {
    static let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")

    final class Calls { var contacts = 0; var avatars = 0 }

    static func rows() -> [InboxRow] {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let names = ["austin", "joker", "leo", "muted"]
        let summaries = names.enumerated().map { index, name in
            CmuxHomeCore.ConversationSummary(
                id: ConversationID("conv_\(name)"),
                participants: [me, Participant(id: ParticipantID("user_\(name)"), kind: .human, displayName: name)],
                lastSeq: 5, createdAt: at, updatedAt: at.addingTimeInterval(Double(60 * (index + 1))), muted: name == "muted")
        }
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }

    @Test func theUnreadConversationsAskForNoDisplayInput() {
        let suite = "cmux.tests.homeUnread.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = Calls()
        let source = HomeSidebarSource(store: HomePinStore(defaults: defaults), account: { "acct" }, rows: { Self.rows() },
                                       me: { Self.me.id }, contacts: { calls.contacts += 1; return [] },
                                       chiefAvatars: { calls.avatars += 1; return [:] })
        source.reloadPins()
        source.setMarkedUnread(true, ConversationID("conv_joker"))
        source.setMarkedUnread(true, ConversationID("conv_muted"))
        source.setPinned(true, ConversationID("conv_leo"))
        source.setMarkedUnread(true, ConversationID("conv_leo"))

        let unread = source.unreadConversations
        #expect(calls.contacts == 0 && calls.avatars == 0, "reading the unread conversations built the list's display model")
        // What the list dots, in its order (pinned first; a muted one never).
        #expect(unread == source.model().unreadConversations)
        #expect(unread.contains(ConversationID("conv_joker")) && unread.contains(ConversationID("conv_leo")))
        #expect(!unread.contains(ConversationID("conv_muted")))
    }
}
