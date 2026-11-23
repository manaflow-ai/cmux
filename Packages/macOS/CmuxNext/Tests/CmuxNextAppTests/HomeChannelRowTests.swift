import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Foundation
import Testing

/// Chief channels (plans/cmux-next/chief-channels-DESIGN.md): a channel lists in Home like any group, with
/// its unread count, and the list tags it "Channel" after its name (VoiceOver reads the tag too).
@MainActor
struct HomeChannelRowTests {
    static let me = ParticipantID("me")

    static func row(_ id: String, channelChief: String?, unread: Seq) -> InboxRow {
        let date = Date(timeIntervalSince1970: 2_000)
        let mine = Participant(id: me, kind: .human, displayName: "Me")
        let others = [Participant(id: ParticipantID("ana"), kind: .human, displayName: "Ana"),
                      Participant(id: ParticipantID("agent_launch"), kind: .agent, displayName: "Launch Chief", agentClass: .chief)]
        let message = Message(id: MessageID("m1"), conversation: ConversationID(id), seq: unread, clientMessageID: IdempotencyKey("c1"), author: ParticipantID("ana"),
                              parts: [.text("hi")], createdAt: date)
        let summary = ConversationSummary(id: ConversationID(id), title: "Launch", participants: [mine] + others, lastSeq: unread,
                                          createdAt: date, updatedAt: date, lastMessage: message, declaredKind: .group,
                                          channelChief: channelChief.map(ParticipantID.init(rawValue:)))
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: mine, conversations: [summary], rev: 1))
        return mirror.inboxRows(log: IntentLog())[0]
    }

    @Test func aChannelIsTaggedAndKeepsItsUnreadState() throws {
        let model = HomeSidebarModel(rows: [Self.row("conv_launch", channelChief: "agent_launch", unread: 2)], pins: HomePins(), me: Self.me)
        let item = try #require(model.rows.first)
        #expect(item.isGroup)
        #expect(item.listBadge == HomeConversationStrings.channelTag)
        #expect(item.unread)
        #expect(item.accessibilityLabel.hasPrefix("Launch, " + HomeConversationStrings.channelTag))
    }

    @Test func aPlainGroupHasNoChannelTag() throws {
        let model = HomeSidebarModel(rows: [Self.row("conv_group", channelChief: nil, unread: 0)], pins: HomePins(), me: Self.me)
        #expect(try #require(model.rows.first).listBadge == nil)
    }
}
