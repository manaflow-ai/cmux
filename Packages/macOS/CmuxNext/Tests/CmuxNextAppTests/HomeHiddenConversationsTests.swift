import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Delete Conversation… on Home (user 2026-10-29: "there are certain people I want to be able to hide
/// or clear up but I can't"): the conversation leaves this account's list and stays gone across
/// launches; a newer message lists it again, and Show Hidden Conversations lists every one again.
@MainActor
@Suite(.serialized) struct HomeHiddenConversationsTests {
    static let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")

    final class Box { var lastSeq: Seq = 3 }

    static func rows(_ box: Box) -> [InboxRow] {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let austin = Participant(id: ParticipantID("user_austin"), kind: .human, displayName: "Austin Wang")
        let joker = Participant(id: ParticipantID("user_joker"), kind: .human, displayName: "joker")
        let summaries = [
            CmuxHomeCore.ConversationSummary(id: ConversationID("conv_austin"), participants: [me, austin], lastSeq: 5,
                                             createdAt: at, updatedAt: at.addingTimeInterval(60)),
            CmuxHomeCore.ConversationSummary(id: ConversationID("conv_joker"), participants: [me, joker], lastSeq: box.lastSeq,
                                             createdAt: at, updatedAt: at.addingTimeInterval(30)),
        ]
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }

    static func source(_ defaults: UserDefaults, _ box: Box) -> HomeSidebarSource {
        let source = HomeSidebarSource(store: HomePinStore(defaults: defaults), account: { "acct" },
                                       rows: { rows(box) }, me: { me.id }, contacts: { [] })
        source.reloadPins()
        return source
    }

    static func listed(_ source: HomeSidebarSource) -> Set<String> {
        let model = source.model()
        return Set((model.pinned + model.rows).map(\.id.rawValue))
    }

    @Test func deleteHidesUntilNewMessageAndPersists() {
        let suite = "cmux.tests.homeHidden.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = Box()
        let source = Self.source(defaults, box)
        #expect(Self.listed(source) == ["conv_austin", "conv_joker"])

        #expect(source.hide(ConversationID("conv_joker")))
        #expect(Self.listed(source) == ["conv_austin"])
        #expect(!source.hide(ConversationID("conv_missing")))

        // The next launch (a new source over the same defaults) keeps it hidden.
        #expect(Self.listed(Self.source(defaults, box)) == ["conv_austin"])

        // A newer message lists it again.
        box.lastSeq = 4
        #expect(Self.listed(source) == ["conv_austin", "conv_joker"])
    }

    @Test func showHiddenListsEveryOneAgain() {
        let suite = "cmux.tests.homeHidden.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = Self.source(defaults, Box())
        source.hide(ConversationID("conv_joker"))
        source.hide(ConversationID("conv_austin"))
        #expect(Self.listed(source).isEmpty)
        #expect(source.unhideAll() == 2)
        #expect(Self.listed(source) == ["conv_austin", "conv_joker"])
        #expect(Self.listed(Self.source(defaults, Box())) == ["conv_austin", "conv_joker"])
    }
}
