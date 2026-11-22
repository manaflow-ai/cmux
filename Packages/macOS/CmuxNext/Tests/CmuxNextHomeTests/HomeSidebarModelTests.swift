import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxNextHome

/// The Home sidebar's data (Lawrence, 2026-10-06: "left ui needs to look like
/// this", macOS Messages' sidebar): a pinned grid with Chiefs pinned by
/// default, rows newest first with Messages' relative times, previews that
/// read reactions ("Lucas loved “Good luck!”") and replies, an unread dot,
/// group composites, and a search over conversations and people.
@Suite struct HomeSidebarModelTests {
    static let me = ParticipantID("user_me")
    static let now = Date(timeIntervalSince1970: 1_791_324_000) // 2026-10-06 22:00 UTC, a Tuesday
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    static let locale = Locale(identifier: "en_US")

    static func person(_ id: String, _ name: String) -> Participant { Participant(id: ParticipantID(id), kind: .human, displayName: name) }
    static let chief = Participant(id: ParticipantID("agent_mux"), kind: .agent, displayName: "Chief", agentClass: .chief)

    static func row(_ id: String, _ others: [Participant], minutesAgo: Double, last: Message? = nil, unread: Int = 0,
                    title: String = "", ownerPin: Int? = nil) -> InboxRow {
        let me = Participant(id: Self.me, kind: .human, displayName: "Me")
        let at = now.addingTimeInterval(-minutesAgo * 60)
        let summary = ConversationSummary(id: ConversationID(id), title: title, participants: [me] + others, lastSeq: Seq(unread),
                                          createdAt: at, updatedAt: at, lastMessage: last, pinRank: ownerPin)
        return InboxRow(summary: summary, kind: summary.kind(me: Self.me), title: summary.displayTitle(me: Self.me),
                        preview: last?.plainText ?? "", previewAttachments: nil, previewAuthor: nil, timestamp: at, unread: unread,
                        isPinned: ownerPin != nil, isSending: false, hasFailedSend: false, isTyping: false)
    }

    static func message(_ id: String, in conversation: String, by author: ParticipantID, _ text: String, minutesAgo: Double,
                        reactions: [Reaction] = [], replyTo: PartRef? = nil) -> Message {
        Message(id: MessageID(id), conversation: ConversationID(conversation), seq: 1, clientMessageID: IdempotencyKey(id), author: author,
                parts: [.text(text)], createdAt: now.addingTimeInterval(-minutesAgo * 60), reactions: reactions, replyTo: replyTo)
    }

    static func model(_ rows: [InboxRow], pins: HomePins = HomePins(), query: String = "", contacts: [HomeContact] = []) -> HomeSidebarModel {
        HomeSidebarModel(rows: rows.orderedForInbox(), pins: pins, me: me, query: query, contacts: contacts, now: now,
                         calendar: calendar, locale: locale)
    }

    static let lucas = person("user_lucas", "Lucas Wang")
    static let austin = person("user_austin", "Austin")
    static let aziz = person("user_aziz", "Aziz Ali")

    static var rows: [InboxRow] {
        let loved = message("m1", in: "conv_lucas", by: me, "Good luck!", minutesAgo: 5,
                            reactions: [Reaction(author: lucas.id, partIndex: 0, kind: .tapback(.love))])
        let reply = message("m2", in: "conv_group", by: austin.id, "Unable to reproduce issue", minutesAgo: 60 * 24,
                            replyTo: PartRef(message: MessageID("m0"), partIndex: 0))
        return [
            row("conv_chief", [chief], minutesAgo: 600),
            row("conv_lucas", [lucas], minutesAgo: 5, last: loved, unread: 1),
            row("conv_group", [austin, aziz, lucas], minutesAgo: 60 * 24, last: reply),
            row("conv_aziz", [aziz], minutesAgo: 60 * 24 * 3),
            row("conv_old", [austin], minutesAgo: 60 * 24 * 10),
        ]
    }

    @Test func chiefsArePinnedByDefaultAndTheRestComeNewestFirst() {
        let model = Self.model(Self.rows)
        #expect(model.pinned.map(\.id.rawValue) == ["conv_chief"])
        #expect(model.pinned.first?.isChief == true)
        #expect(model.rows.map(\.id.rawValue) == ["conv_lucas", "conv_group", "conv_aziz", "conv_old"])
    }

    @Test func userPinsComeFirstInTheirOrderAndAnUnpinnedChiefIsARow() {
        var pins = HomePins()
        let rows = Self.rows
        pins.setPinned(true, rows[3])
        pins.setPinned(true, rows[1])
        pins.setPinned(false, rows[0])
        let model = Self.model(rows, pins: pins)
        #expect(model.pinned.map(\.id.rawValue) == ["conv_aziz", "conv_lucas"])
        #expect(model.rows.map(\.id.rawValue) == ["conv_chief", "conv_group", "conv_old"], "an unpinned Chief takes its place by time")
        #expect(pins.unpinned == [ConversationID("conv_chief")])
    }

    @Test func timesReadLikeMessages() {
        let times = Dictionary(uniqueKeysWithValues: Self.model(Self.rows).rows.map { ($0.id.rawValue, $0.time) })
        #expect(times["conv_lucas"] == "9:55\u{202F}PM", "the locale's own time (a narrow space before PM)")
        #expect(times["conv_group"] == "Yesterday")
        #expect(times["conv_aziz"] == "Saturday")
        #expect(times["conv_old"] == "9/26/26")
    }

    @Test func previewsReadReactionsAndRepliesAndUnreadIsADot() throws {
        let model = Self.model(Self.rows)
        let lucas = try #require(model.rows.first { $0.id.rawValue == "conv_lucas" })
        #expect(lucas.preview == "Lucas Wang loved “Good luck!”")
        #expect(lucas.unread && lucas.unreadCount == 1)
        let group = try #require(model.rows.first { $0.id.rawValue == "conv_group" })
        #expect(group.isReply && group.preview == "Unable to reproduce issue")
        #expect(!group.unread)
        #expect(group.accessibilityLabel.contains(group.title) && group.accessibilityLabel.contains("Yesterday"))
        #expect(lucas.accessibilityLabel.contains(HomeConversationStrings.unread(1)))
    }

    @Test func aGroupIsACompositeOfUpToThreeMembersWithABadge() throws {
        let model = Self.model(Self.rows)
        let group = try #require(model.rows.first { $0.id.rawValue == "conv_group" })
        #expect(group.isGroup)
        #expect(group.avatars.map(\.initials) == ["A", "AA", "LW"])
        #expect(group.badge == "A")
        let dm = try #require(model.rows.first { $0.id.rawValue == "conv_lucas" })
        #expect(!dm.isGroup && dm.badge == nil && dm.avatars.map(\.initials) == ["LW"])
    }

    @Test func searchFiltersConversationsAndListsNewPeople() {
        let contacts = [HomeContact(id: Self.aziz.id, name: "Aziz Ali", source: .team),
                        HomeContact(id: ParticipantID("user_zoe"), name: "Zoe Azizi", source: .team)]
        let model = Self.model(Self.rows, query: "aziz", contacts: contacts)
        #expect(model.pinned.isEmpty)
        #expect(model.rows.map(\.id.rawValue) == ["conv_group", "conv_aziz"], "a member's name matches too")
        #expect(model.people.map(\.name) == ["Zoe Azizi"], "Aziz already has a DM")
        #expect(Self.model(Self.rows, query: "good luck").rows.map(\.id.rawValue) == ["conv_lucas"], "previews match")
        #expect(Self.model(Self.rows, query: "me").rows.isEmpty, "my own name matches nothing")
    }
}

/// Cmd-Shift-[ / ]: the previous or next conversation in the list's visual
/// order (the pinned grid, then the rows); it stops at the ends, as Messages does.
extension HomeSidebarModelTests {
    @Test func neighborsFollowTheListAndStopAtTheEnds() {
        let model = Self.model(Self.rows)
        let order = (model.pinned + model.rows).map(\.id)
        #expect(order.map(\.rawValue) == ["conv_chief", "conv_lucas", "conv_group", "conv_aziz", "conv_old"])
        #expect(model.neighbor(of: order[0], offset: 1) == order[1])
        #expect(model.neighbor(of: order[2], offset: -1) == order[1])
        #expect(model.neighbor(of: order[0], offset: -1) == nil, "stops at the top")
        #expect(model.neighbor(of: order[4], offset: 1) == nil, "stops at the bottom")
        #expect(model.neighbor(of: nil, offset: 1) == order[0], "nothing shown: the first")
        #expect(model.neighbor(of: ConversationID("gone"), offset: -1) == order[0])
    }
}
