import AppKit
@testable import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// The Home page's left column (Lawrence, 2026-10-05: "left sidebar UI for
/// DMing each other too and creating multiple chiefs, optionally"): the
/// merged inbox with Chiefs first, then pinned conversations, then DMs and
/// groups by recency, then DMs waiting for an invited person; unread and
/// mention badges; arrow keys move between conversations; choosing one asks
/// the host to show it.
@MainActor
@Suite struct HomeConversationListTests {
    static let me = ParticipantID("user_me")
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func person(_ id: String, _ name: String, invited: Bool = false) -> Participant {
        Participant(id: ParticipantID(id), kind: .human, displayName: name, membership: invited ? .invited : .active,
                    invitedContact: invited ? "\(name.lowercased())@example.com" : nil)
    }

    static func chief(_ id: String, _ name: String) -> Participant {
        Participant(id: ParticipantID(id), kind: .agent, displayName: name, agentClass: .chief, ownerUser: me)
    }

    static func row(_ id: String, with others: [Participant], at minutes: Double, unread: Int = 0, mentions: Int = 0,
                    pin: Int? = nil, title: String = "") -> InboxRow {
        let me = Participant(id: Self.me, kind: .human, displayName: "Me")
        let summary = ConversationSummary(id: ConversationID(id), title: title, participants: [me] + others, lastSeq: Seq(unread),
                                          createdAt: base, updatedAt: base.addingTimeInterval(minutes * 60), pinRank: pin,
                                          mentionCount: mentions)
        return InboxRow(summary: summary, kind: summary.kind(me: Self.me), title: summary.displayTitle(me: Self.me), preview: "hi",
                        previewAttachments: nil, previewAuthor: nil, timestamp: summary.updatedAt, unread: unread, mentions: mentions,
                        isPinned: pin != nil, isSending: false, hasFailedSend: false, isTyping: false)
    }

    static var rows: [InboxRow] {
        [
            row("conv_austin", with: [person("user_austin", "Austin")], at: 9, unread: 2, mentions: 1),
            row("conv_chief", with: [chief("agent_mux", "Chief")], at: 1),
            row("conv_group", with: [person("user_austin", "Austin"), person("user_aziz", "Aziz")], at: 5, title: "Launch"),
            row("conv_pinned", with: [person("user_aziz", "Aziz")], at: 0, pin: 0),
            row("conv_invited", with: [person("addr_X", "Lee", invited: true)], at: 7),
            row("conv_sub", with: [chief("agent_research", "Research")], at: 3),
        ].orderedForInbox()
    }

    @Test func chiefsComeFirstThenPinnedThenMessagesByRecencyThenInvited() {
        let sections = Self.rows.homeSections
        #expect(sections.map(\.kind) == [.chiefs, .pinned, .messages, .invited])
        #expect(sections[0].rows.map(\.id.rawValue) == ["conv_sub", "conv_chief"])
        #expect(sections[1].rows.map(\.id.rawValue) == ["conv_pinned"])
        #expect(sections[2].rows.map(\.id.rawValue) == ["conv_austin", "conv_group"])
        #expect(sections[3].rows.map(\.id.rawValue) == ["conv_invited"])
        #expect(Self.rows.pendingInvites.map(\.contact) == ["lee@example.com"])
    }

    /// Chiefs are optional: someone with only DMs sees no Chiefs section.
    @Test func withoutChiefsThereIsNoChiefsSection() {
        let rows = [Self.row("conv_austin", with: [Self.person("user_austin", "Austin")], at: 1)]
        #expect(rows.homeSections.map(\.kind) == [.messages])
    }

    @Test func connectionsAreTheActivePeopleOfMyDMs() {
        let contacts = HomeContact.connections(in: Self.rows, me: Self.me)
        #expect(contacts.map(\.id.rawValue) == ["user_aziz", "user_austin"], "newest DM first, the pinned one ahead")
        let merged = HomeContact.merged(team: [HomeContact(id: ParticipantID("user_aziz"), name: "Aziz", source: .team),
                                               HomeContact(id: ParticipantID("user_ben"), name: "Ben", source: .team)],
                                        connections: contacts)
        #expect(merged.map(\.name) == ["Aziz", "Ben", "Austin"])
        #expect(merged.map(\.source) == [.team, .team, .connection])
    }

    @Test func chiefCompactorErrorsAreNotShownAsPreviews() {
        var row = Self.row("conv_chief_error", with: [Self.chief("agent_mux", "Chief")], at: 1)
        row.preview = "The memory compactor cannot build summaries (acpmux route: unavailable)"
        #expect(HomeConversationCellView.previewText(row).isEmpty)
    }

    @Test func choosingARowAsksTheHostAndArrowKeysSkipHeaders() throws {
        let list = HomeConversationListView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        var chosen: [String] = []
        list.onSelect = { chosen.append($0.rawValue) }
        list.update(rows: Self.rows, me: Self.me)
        list.layoutSubtreeIfNeeded()
        #expect(list.table.numberOfRows == 10, "4 headers and 6 conversations")
        list.select(ConversationID("conv_chief"))
        #expect(chosen.isEmpty, "a selection the host made is not echoed")
        list.table.step(1)
        #expect(chosen == ["conv_pinned"], "down from the last Chief skips the Pinned header")
        list.table.step(-1)
        #expect(chosen == ["conv_pinned", "conv_chief"])
        #expect(list.selection == ConversationID("conv_chief"))
    }

    @Test func aRowSaysItsUnreadAndMentionStateToVoiceOver() throws {
        let list = HomeConversationListView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        list.update(rows: Self.rows, me: Self.me)
        let index = try #require(list.lines.firstIndex { $0.conversation?.rawValue == "conv_austin" })
        let cell = try #require(list.tableView(list.table, viewFor: nil, row: index) as? HomeConversationCellView)
        #expect(!cell.badge.isHidden && cell.badge.stringValue == "2")
        #expect(!cell.mention.isHidden)
        let label = try #require(cell.accessibilityLabel())
        #expect(label.contains("Austin") && label.contains(HomeConversationStrings.unread(2)) && label.contains(HomeConversationStrings.mentioned))
    }

    @Test func thePlusMenuOffersNewMessageNewChiefAndInvite() {
        let list = HomeConversationListView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        var picked: [String] = []
        list.onNewMessage = { picked.append("message") }
        list.onNewChief = { picked.append("chief") }
        list.onInvite = { picked.append("invite") }
        let menu = list.addMenu()
        #expect(menu.items.map(\.title) == [HomeConversationStrings.newMessage, HomeConversationStrings.newChief, HomeConversationStrings.invite])
        for item in menu.items { _ = item.target?.perform(item.action) }
        #expect(picked == ["message", "chief", "invite"])
        #expect(list.addButton.accessibilityLabel() != nil)
    }

    @Test func theComposeSheetStartsWithThePickedPeopleAndOffersAnInviteWhenRefused() async throws {
        let sheet = HomeComposeSheet(contacts: [HomeContact(id: ParticipantID("user_austin"), name: "Austin", source: .team),
                                                HomeContact(id: ParticipantID("user_aziz"), name: "Aziz", source: .team)])
        _ = sheet.view
        var started: [[HomeRecipient]] = []
        sheet.onStart = { recipients, _ in
            started.append(recipients)
            return .notReachable("Austin")
        }
        #expect(!sheet.primaryButton.isEnabled, "nothing picked")
        sheet.search.stringValue = "aus"
        sheet.refilter()
        #expect(sheet.shown.map(\.label) == ["Austin"])
        sheet.toggle(0)
        #expect(sheet.primaryButton.isEnabled)
        #expect(sheet.groupName.isHidden, "one person is a DM")
        sheet.search.stringValue = "lee@example.com"
        sheet.refilter()
        #expect(sheet.shown.first == .address(.email("lee@example.com")))
        sheet.primary(nil)
        for _ in 0..<100 where sheet.isRunning { await Task.yield() }
        #expect(started == [[.contact(HomeContact(id: ParticipantID("user_austin"), name: "Austin", source: .team))]])
        #expect(!sheet.statusLabel.isHidden && sheet.statusLabel.stringValue.contains("Austin"))
        #expect(!sheet.inviteButton.isHidden, "a refused person gets Invite by Email")
    }

    /// No teammates and no contacts yet: the sheet says how to reach someone.
    @Test func theComposeSheetSaysHowToReachSomeoneWithoutContacts() {
        let empty = HomeComposeSheet(contacts: [])
        _ = empty.view
        #expect(!empty.emptyLabel.isHidden)
        #expect(empty.emptyLabel.stringValue == HomeConversationStrings.composeNoContacts)
        empty.search.stringValue = "lee@example.com"
        empty.refilter()
        #expect(empty.emptyLabel.isHidden, "a typed address is a row to pick")
        let full = HomeComposeSheet(contacts: [HomeContact(id: ParticipantID("user_a"), name: "Austin", source: .team)])
        _ = full.view
        #expect(full.emptyLabel.isHidden)
    }
}
