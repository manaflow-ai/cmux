import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing

/// New Message is a page, as in Messages (Lawrence 2026-10-19: "it makes a modal but iMessage
/// just creates a new page and you can type out their contacts or email addresses"): a To: field
/// whose text becomes tokens (Return, comma, Tab; Backspace removes the last), live suggestions,
/// red tokens for nobody, the existing conversation of exactly those people, a "New Message" row
/// at the top of the list, and a blank page whose first send makes the conversation.
@MainActor @Suite(.closesItsWindows)
struct HomeNewMessageTests {
    static let me = ParticipantID("me")
    static let ada = HomeContact(id: ParticipantID("ada"), name: "Ada Lovelace", source: .team)
    static let alan = HomeContact(id: ParticipantID("alan"), name: "Alan Turing", source: .connection)
    static let grace = HomeContact(id: ParticipantID("grace"), name: "Grace Hopper", source: .team)
    static let chief = HomeContact(id: ParticipantID("chief-1"), name: "Chief", source: .agent)
    static let contacts = [ada, alan, grace, chief]

    // MARK: Tokens

    @Test func returnTurnsAnEmailOrPhoneIntoAnAddressToken() {
        var draft = HomeNewMessageDraft()
        draft.query = " Austin@Manaflow.ai "
        let committed = draft.commit(contacts: Self.contacts)
        #expect(committed)
        draft.query = "(415) 555-0134"
        draft.commit(contacts: Self.contacts)
        #expect(draft.recipients == [.address(.email("austin@manaflow.ai")), .address(.phone("+14155550134"))])
        #expect(draft.query.isEmpty)
        #expect(!draft.hasInvalidTokens)
    }

    @Test func aNameResolvesToItsContactByFullNameOrAUniquePrefix() {
        var draft = HomeNewMessageDraft()
        draft.query = "ada lovelace"
        draft.commit(contacts: Self.contacts)
        draft.query = "Gra"
        draft.commit(contacts: Self.contacts)
        #expect(draft.recipients == [.contact(Self.ada), .contact(Self.grace)])
        #expect(draft.tokens.map(\.text) == ["Ada Lovelace", "Grace Hopper"])
        #expect(draft.isGroup)
    }

    @Test func textThatNamesNobodyIsARedTokenThatBlocksTheMatch() {
        var draft = HomeNewMessageDraft()
        draft.query = "nobody"
        draft.commit(contacts: Self.contacts)
        draft.query = "not-an@email"
        draft.commit(contacts: Self.contacts)
        #expect(draft.tokens.map(\.isValid) == [false, false])
        #expect(draft.hasInvalidTokens)
        #expect(draft.recipients.isEmpty)
        draft.add(.contact(Self.ada))
        #expect(draft.existingConversation(in: [Self.row("dm-ada", [Self.ada.id])], me: Self.me) == nil)
    }

    @Test func theFirstSendWaitsForAValidRecipient() {
        var draft = HomeNewMessageDraft()
        #expect(draft.sendBlocker == HomeConversationStrings.needsRecipient)
        draft.query = "nobody"
        draft.commit(contacts: Self.contacts)
        draft.add(.contact(Self.ada))
        #expect(draft.sendBlocker == HomeConversationStrings.unknownRecipient("nobody"))
        draft.remove(at: 0)
        #expect(draft.sendBlocker == nil)
    }

    @Test func backspaceWithNothingTypedRemovesTheLastToken() {
        var draft = HomeNewMessageDraft()
        draft.add(.contact(Self.ada))
        draft.add(.contact(Self.alan))
        draft.query = "x"
        let typedStays = draft.deleteBackward()
        #expect(!typedStays)
        #expect(draft.tokens.count == 2)
        draft.query = ""
        let removedOne = draft.deleteBackward()
        #expect(removedOne)
        #expect(draft.recipients == [.contact(Self.ada)])
        draft.deleteBackward()
        let removedNone = draft.deleteBackward()
        #expect(!removedNone)
        #expect(draft.isEmpty)
    }

    @Test func aRecipientIsAddedOnce() {
        var draft = HomeNewMessageDraft()
        draft.add(.contact(Self.ada))
        draft.query = "Ada Lovelace"
        draft.commit(contacts: Self.contacts)
        #expect(draft.tokens.count == 1)
    }

    // MARK: Suggestions

    @Test func suggestionsPutATypedAddressFirstThenWordStartsThenContains() {
        var draft = HomeNewMessageDraft()
        draft.query = "a"
        // Word starts: Ada (Ada), Alan (Alan); contains: Grace Hopper (gr-a-ce); Chief has no "a".
        #expect(draft.suggestions(contacts: Self.contacts) == [.contact(Self.ada), .contact(Self.alan), .contact(Self.grace)])
        draft.query = "tur"
        #expect(draft.suggestions(contacts: Self.contacts) == [.contact(Self.alan)])
        draft.query = "ada@x.com"
        #expect(draft.suggestions(contacts: Self.contacts).first == .address(.email("ada@x.com")))
        draft.query = ""
        #expect(draft.suggestions(contacts: Self.contacts).isEmpty)
    }

    @Test func suggestionsLeaveOutPeopleAlreadyChosen() {
        var draft = HomeNewMessageDraft()
        draft.add(.contact(Self.ada))
        draft.query = "a"
        #expect(!draft.suggestions(contacts: Self.contacts).contains(.contact(Self.ada)))
    }

    @Test func chiefsAreSuggestedByName() {
        var draft = HomeNewMessageDraft()
        draft.query = "chi"
        #expect(draft.suggestions(contacts: Self.contacts) == [.contact(Self.chief)])
        #expect(HomeRecipientSuggestionsView.detail(.contact(Self.chief)) == HomeConversationStrings.sourceAgent)
    }

    // MARK: The existing conversation

    @Test func onePersonShowsTheirDMAndSeveralShowTheGroupWithExactlyThem() {
        let rows = [
            Self.row("group-big", [Self.ada.id, Self.alan.id, Self.grace.id]),
            Self.row("dm-ada", [Self.ada.id]),
            Self.row("group-two", [Self.ada.id, Self.alan.id]),
            Self.row("chief", [Self.chief.id]),
        ]
        var draft = HomeNewMessageDraft()
        draft.add(.contact(Self.ada))
        #expect(draft.existingConversation(in: rows, me: Self.me) == ConversationID("dm-ada"))
        draft.add(.contact(Self.alan))
        #expect(draft.existingConversation(in: rows, me: Self.me) == ConversationID("group-two"))
        draft.add(.contact(Self.grace))
        #expect(draft.existingConversation(in: rows, me: Self.me) == ConversationID("group-big"))
        var chief = HomeNewMessageDraft()
        chief.add(.contact(Self.chief))
        #expect(chief.existingConversation(in: rows, me: Self.me) == ConversationID("chief"))
        var nobody = HomeNewMessageDraft()
        nobody.add(.contact(Self.grace))
        #expect(nobody.existingConversation(in: rows, me: Self.me) == nil, "Grace has no DM: the page is blank")
    }

    @Test func anAddressMatchesThePersonInvitedByIt() {
        let invited = Participant(id: ParticipantID("p-austin"), kind: .human, displayName: "", membership: .invited,
                                  invitedContact: "austin@manaflow.ai")
        let rows = [Self.row("dm-austin", participants: [invited])]
        var draft = HomeNewMessageDraft()
        draft.query = "austin@manaflow.ai"
        draft.commit(contacts: [])
        #expect(draft.existingConversation(in: rows, me: Self.me) == ConversationID("dm-austin"))
    }

    // MARK: Contacts

    @Test func newMessageOffersTheUsersChiefsAfterPeople() {
        let chiefParticipant = Participant(id: Self.chief.id, kind: .agent, displayName: "Chief", agentClass: .chief)
        let rows = [Self.row("chief", participants: [chiefParticipant])]
        let agents = HomeContact.agents(in: rows, me: Self.me)
        #expect(agents == [HomeContact(id: Self.chief.id, name: "Chief", source: .agent)])
        let merged = HomeContact.merged(team: [Self.grace, Self.ada], connections: [Self.alan, Self.ada], agents: agents)
        #expect(merged.map(\.id) == [Self.ada.id, Self.grace.id, Self.alan.id, Self.chief.id])
    }

    // MARK: The To: field

    @Test func theFieldTokenizesOnReturnCommaAndTab() throws {
        let field = Self.field()
        field.text.stringValue = "Ada"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.suggestions.items == [.contact(Self.ada)], "typing suggests")
        #expect(field.handle(#selector(NSResponder.insertNewline(_:))))
        #expect(field.draft.recipients == [.contact(Self.ada)])
        #expect(field.text.stringValue.isEmpty)
        field.text.stringValue = "grace@example.com,"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.draft.recipients.last == .address(.email("grace@example.com")), "a comma ends the token")
        field.text.stringValue = "zzz"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.handle(#selector(NSResponder.insertTab(_:))))
        #expect(field.draft.tokens.last?.isValid == false)
        let red = try #require(field.chips.last)
        #expect(!red.token.isValid)
        #expect(field.chips.count == 3)
    }

    @Test func returnWithNothingTypedGoesToTheMessageBoxAndBackspaceRemovesATokens() {
        let field = Self.field()
        var done = 0
        field.onDone = { done += 1 }
        field.choose(.contact(Self.ada))
        field.choose(.contact(Self.alan))
        #expect(field.handle(#selector(NSResponder.insertNewline(_:))))
        #expect(done == 1)
        #expect(field.handle(#selector(NSResponder.deleteBackward(_:))))
        #expect(field.draft.recipients == [.contact(Self.ada)])
        field.text.stringValue = "x"
        #expect(!field.handle(#selector(NSResponder.deleteBackward(_:))), "Backspace edits typed text")
    }

    @Test func aClickedTokenIsTheOneBackspaceRemoves() {
        let field = Self.field()
        field.choose(.contact(Self.ada))
        field.choose(.contact(Self.alan))
        field.chips[0].mouseDown(with: Self.click())
        #expect(field.chips[0].isSelected)
        #expect(field.handle(#selector(NSResponder.deleteBackward(_:))))
        #expect(field.draft.recipients == [.contact(Self.alan)])
    }

    @Test func upAndDownMoveThroughSuggestionsAndReturnChoosesTheHighlightedOne() {
        let field = Self.field()
        field.text.stringValue = "a"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.suggestions.items.count == 3)
        #expect(field.handle(#selector(NSResponder.moveDown(_:))))
        #expect(field.suggestions.highlighted == 1)
        field.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(field.draft.recipients == [.contact(Self.alan)])
        #expect(field.suggestions.isHidden)
    }

    @Test func escapeClosesSuggestionsFirstThenAsksThePageToLeave() {
        let field = Self.field()
        var escaped = 0
        field.onEscape = { escaped += 1 }
        field.text.stringValue = "a"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.handle(#selector(NSResponder.cancelOperation(_:))))
        #expect(field.suggestions.isHidden)
        #expect(escaped == 0)
        field.handle(#selector(NSResponder.cancelOperation(_:)))
        #expect(escaped == 1)
    }

    @Test func beforeAnythingIsTypedTheListOffersTheChiefsAndDownThenReturnPicksOne() {
        let field = Self.field()
        let unii = HomeContact(id: ParticipantID("agent_unii"), name: "Unii", source: .agent)
        field.idleSuggestions = { [Self.chief, unii].filter { !field.draft.recipients.contains(.contact($0)) } }
        var done = 0
        field.onDone = { done += 1 }
        field.refreshSuggestions()
        #expect(!field.suggestions.isHidden)
        #expect(field.suggestions.items == [.contact(Self.chief), .contact(unii)])
        #expect(field.suggestions.highlighted == nil, "nothing is picked until the person moves")
        field.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(done == 1)
        #expect(field.draft.recipients.isEmpty)
        #expect(field.handle(#selector(NSResponder.moveDown(_:))))
        #expect(field.handle(#selector(NSResponder.moveDown(_:))))
        field.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(field.draft.recipients == [.contact(unii)])
        #expect(field.suggestions.isHidden, "once someone is chosen the list waits for typing")
    }

    @Test func tabWithNothingTypedGoesToTheMessageBoxEvenWithASuggestionHighlighted() {
        let field = Self.field()
        var done = 0
        field.onDone = { done += 1 }
        field.addButton.performClick(nil)
        #expect(field.suggestions.highlighted == 0)
        field.handle(#selector(NSResponder.insertTab(_:)))
        #expect(done == 1)
        #expect(field.draft.recipients.isEmpty)
    }

    @Test func escapeWithTheChiefsListedAsksThePageToLeave() {
        let field = Self.field()
        field.idleSuggestions = { [Self.chief] }
        var escaped = 0
        field.onEscape = { escaped += 1 }
        field.refreshSuggestions()
        field.handle(#selector(NSResponder.cancelOperation(_:)))
        #expect(escaped == 1)
    }

    /// Two Chiefs named "Chief" (the Hosted Chief and this Mac's) were two identical "+ Ch…" pills.
    @Test func eachSuggestionShowsItsFullNameAndChiefsSayWhereTheyRun() throws {
        let cloud = HomeContact(id: ParticipantID("agent_cloud"), name: "Chief", source: .agent)
        let mac = HomeContact(id: ParticipantID("agent_mux"), name: "Chief", source: .agent)
        let list = HomeRecipientSuggestionsView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        list.look = { recipient in
            guard case .contact(let contact) = recipient, contact.source == .agent else { return HomeRecipientLook() }
            return HomeRecipientLook(avatar: .chiefDefault, tag: contact == cloud ? "Main \u{00B7} Cloud" : "This Mac")
        }
        list.show([.contact(cloud), .contact(mac), .contact(Self.ada)], highlightFirst: false)
        let labels = try (0..<3).map { try #require(list.tableView(list.table, viewFor: nil, row: $0)?.accessibilityLabel()) }
        let chief = HomeConversationStrings.sourceAgent
        #expect(labels == ["Chief, \(chief) \u{00B7} Main \u{00B7} Cloud", "Chief, \(chief) \u{00B7} This Mac",
                           "Ada Lovelace, \(HomeConversationStrings.sourceTeam)"])
        #expect(Set(labels).count == 3)
    }

    // MARK: Sections, New Chief and telling Chiefs apart (user 2026-10-27)

    /// Before anything is typed, To: lists the Chiefs and the team in their own sections, with a
    /// New Chief row after the Chiefs: Down reaches it and Return makes a Chief.
    @Test func theIdleListHasChiefAndTeamSectionsAndANewChiefRow() {
        let field = Self.field()
        let unii = HomeContact(id: ParticipantID("agent_unii"), name: "Unii", source: .agent)
        field.idleSuggestions = { [Self.chief, unii, Self.ada, Self.grace] }
        var made = 0
        field.onNewChief = { made += 1 }
        field.refreshSuggestions()
        #expect(field.suggestions.rows == [
            .header(HomeConversationStrings.chiefsSection), .recipient(.contact(Self.chief)), .recipient(.contact(unii)), .newChief,
            .header(HomeConversationStrings.teamSection), .recipient(.contact(Self.ada)), .recipient(.contact(Self.grace)),
        ])
        #expect(field.suggestions.items == [.contact(Self.chief), .contact(unii), .contact(Self.ada), .contact(Self.grace)])
        for _ in 0..<3 { field.handle(#selector(NSResponder.moveDown(_:))) }
        #expect(field.suggestions.highlightedRow == .newChief)
        field.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(made == 1)
        #expect(field.draft.recipients.isEmpty, "New Chief adds no token")
        field.handle(#selector(NSResponder.moveDown(_:)))
        field.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(field.draft.recipients == [.contact(Self.ada)], "Down after New Chief reaches the team")
    }

    /// With no teammates the Team section offers an invite instead of hiding.
    @Test func anEmptyTeamOffersAnInvite() {
        let field = Self.field()
        field.idleSuggestions = { [Self.chief] }
        var invited = 0
        field.onNewChief = {}
        field.onInvite = { invited += 1 }
        field.refreshSuggestions()
        #expect(field.suggestions.rows == [
            .header(HomeConversationStrings.chiefsSection), .recipient(.contact(Self.chief)), .newChief,
            .header(HomeConversationStrings.teamSection), .invite,
        ])
        for _ in 0..<3 { field.handle(#selector(NSResponder.moveDown(_:))) }
        #expect(field.suggestions.highlightedRow == .invite, "Down skips the Team header")
        field.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(invited == 1)
    }

    /// Headers are not rows a click or Return can pick.
    @Test func aHeaderIsNeverPicked() {
        let field = Self.field()
        field.idleSuggestions = { [Self.chief, Self.ada] }
        field.refreshSuggestions()
        #expect(!field.suggestions.tableView(field.suggestions.table, shouldSelectRow: 0))
        #expect(field.suggestions.tableView(field.suggestions.table, shouldSelectRow: 1))
    }

    /// Two Chiefs named "Chief" on this Mac were two identical "Chief · This Mac" rows: rows that
    /// read the same also show when each was last active, else a number.
    @Test func twoChiefsThatReadTheSameAreToldApart() throws {
        let one = HomeContact(id: ParticipantID("agent_one"), name: "Chief", source: .agent)
        let two = HomeContact(id: ParticipantID("agent_two"), name: "Chief", source: .agent)
        let three = HomeContact(id: ParticipantID("agent_three"), name: "Chief", source: .agent)
        let list = HomeRecipientSuggestionsView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        list.look = { recipient in
            guard case .contact(let contact) = recipient, contact.source == .agent else { return HomeRecipientLook() }
            let activity: String? = contact == one ? "Active 2h ago" : contact == two ? "Active yesterday" : "Active yesterday"
            return HomeRecipientLook(avatar: .chiefDefault, tag: "This Mac", activity: activity)
        }
        list.show([.contact(one), .contact(two), .contact(three), .contact(Self.ada)], highlightFirst: false)
        let labels = try (0..<4).map { try #require(list.tableView(list.table, viewFor: nil, row: $0)?.accessibilityLabel()) }
        #expect(Set(labels).count == 4, "\(labels)")
        #expect(labels[0].contains("Active 2h ago"))
        #expect(labels[1].contains("Active yesterday"))
        #expect(labels[3] == "Ada Lovelace, \(HomeConversationStrings.sourceTeam)", "a unique row stays short")
    }

    @Test func plusListsEveryoneNotChosenYet() {
        let field = Self.field()
        field.choose(.contact(Self.ada))
        field.addButton.performClick(nil)
        #expect(field.suggestions.items == [.contact(Self.alan), .contact(Self.grace), .contact(Self.chief)])
        let empty = HomeRecipientField(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        empty.browse()
        #expect(!empty.suggestions.isHidden, "with nobody to pick the + says how to reach someone")
        #expect(empty.suggestions.items.isEmpty)
    }

    @Test func tokensWrapToMoreLinesAndTheFieldGrows() {
        let field = Self.field()
        let one = field.height(forWidth: 360)
        for contact in Self.contacts { field.choose(.contact(contact)) }
        #expect(field.height(forWidth: 360) > one)
    }

    @Test func theToFieldDrawsTheThemeNotAnAppKitBezel() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let field = Self.field()
        scope.root(field)
        #expect(!field.text.isBezeled && !field.text.drawsBackground && !field.text.isBordered)
        let ink = scope.perform { Palette.textPrimary }
        #expect(field.text.textColor.map { ThemedOverlayColorsTests.same($0, ink) } == true)
    }

    // MARK: The list's New Message row

    @Test func theDraftRowSitsFirstUnderThePinsAndGoesAway() {
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let pinned = Self.row("pinned", [Self.ada.id])
        let other = Self.row("other", [Self.alan.id])
        var pins = HomePins()
        pins.setPinned(true, pinned)
        sidebar.update(HomeSidebarModel(rows: [pinned, other], pins: pins, me: Self.me))
        sidebar.setDraftRow(HomeNewMessageDraft.rowTitle)
        let ids = sidebar.list.entries.map(\.id)
        #expect(ids == ["pinned", HomeSidebarView.draftRowID.rawValue, "other"])
        let row = sidebar.list.entries[1]
        #expect(row.title == HomeConversationStrings.composeTitle)
        #expect(row.lastAt == .distantPast, "no time on the draft row, as in Messages")
        // A list update keeps it; removing it leaves the conversations only.
        sidebar.update(HomeSidebarModel(rows: [pinned, other, Self.row("new", [Self.grace.id])], pins: pins, me: Self.me))
        #expect(sidebar.list.entries.map(\.id).contains(HomeSidebarView.draftRowID.rawValue))
        sidebar.setDraftRow(nil)
        #expect(!sidebar.list.entries.map(\.id).contains(HomeSidebarView.draftRowID.rawValue))
    }

    /// The user, 2026-10-30: "on hover on new message should be x button". Only the draft row
    /// carries the x; its click asks the page to discard the draft; without a draft no row has one.
    @Test func theDraftRowAloneCarriesAnXThatAsksThePageToDiscardTheDraft() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        window.contentView = sidebar
        var closes = 0
        sidebar.onCloseDraft = { closes += 1 }
        sidebar.update(HomeSidebarModel(rows: [Self.row("other", [Self.alan.id])], pins: HomePins(), me: Self.me))
        #expect(sidebar.list.closableID == nil)
        sidebar.setDraftRow(HomeNewMessageDraft.rowTitle)
        #expect(sidebar.list.closableID == HomeSidebarView.draftRowID.rawValue)
        #expect(sidebar.list.closeTitle == HomeConversationStrings.closeNewMessage)
        sidebar.list.onClose("other")
        #expect(closes == 0, "a conversation's row has no x")
        sidebar.list.onClose(HomeSidebarView.draftRowID.rawValue)
        #expect(closes == 1)
        sidebar.setDraftRow(nil)
        #expect(sidebar.list.closableID == nil)
    }

    // MARK: The blank page's first send

    @Test func theComposerSourceHandsOnlyTheFirstSendToThePage() async throws {
        let me = Participant(id: Self.me, kind: .human, displayName: "Me")
        let sent = SentParts()
        let source = HomeNewMessageComposerSource(me: me) { parts in
            await sent.add(parts)
            return HomeOpResult(rev: 1, conversation: ConversationID("dm-new"))
        }
        let draft = HomeNewMessageComposerSource.conversation
        let page = try await source.snapshot(of: draft, tail: 50)
        #expect(page.messages.isEmpty)
        #expect(page.conversation.participants.map(\.id) == [Self.me])
        let result = try await source.submit(HomeIntent(op: .sendMessage(conversation: draft, parts: [.text("hi Ada")])))
        #expect(result.conversation == ConversationID("dm-new"))
        #expect(await sent.all == [[.text("hi Ada")]])
        await #expect(throws: HomeRejection.self) {
            try await source.submit(HomeIntent(op: .setReadCursor(conversation: draft, seq: 1)))
        }
        await #expect(throws: HomeRejection.self) {
            try await source.snapshot(of: ConversationID("someone-elses"), tail: 1)
        }
    }

    @Test func returnInTheBlankPagesMessageBoxReachesTheFirstSendThroughTheStore() async throws {
        let me = Participant(id: Self.me, kind: .human, displayName: "Me")
        let sent = SentParts()
        let source = HomeNewMessageComposerSource(me: me) { parts in
            await sent.add(parts)
            return HomeOpResult(rev: 1, conversation: ConversationID("dm-new"))
        }
        let store = HomeStore(source: source, blobCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("home-new-message-\(UUID().uuidString)"))
        store.start()
        defer { store.stop() }
        let draft = HomeNewMessageComposerSource.conversation
        await store.open(draft)
        // The store goes online from the source's first events (no clock involved).
        for _ in 0..<1_000 where !store.isOnline { await Task.yield() }
        #expect(store.isOnline)
        _ = try await store.perform(.sendMessage(conversation: draft, parts: [.text("first")]))
        #expect(await sent.all == [[.text("first")]])
    }

    // MARK: Helpers

    static func field() -> HomeRecipientField {
        let field = HomeRecipientField(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        field.contacts = { Self.contacts }
        return field
    }

    static func click() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// One inbox row as the store derives it (its kind from its members: one human is a DM, a
    /// Chief is the Chief's conversation, two or more others a group).
    static func row(_ id: String, _ others: [ParticipantID]) -> InboxRow {
        row(id, participants: others.map { other in
            other == chief.id ? Participant(id: other, kind: .agent, displayName: "Chief", agentClass: .chief)
                : Participant(id: other, kind: .human, displayName: other.rawValue)
        })
    }

    static func row(_ id: String, participants: [Participant]) -> InboxRow {
        let at = Date(timeIntervalSince1970: 1_000)
        let mine = Participant(id: me, kind: .human, displayName: "Me")
        let summary = ConversationSummary(id: ConversationID(id), participants: [mine] + participants, createdAt: at, updatedAt: at)
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: mine, conversations: [summary], rev: 1))
        return mirror.inboxRows(log: IntentLog())[0]
    }
}

/// The parts the page's first send received.
private actor SentParts {
    private(set) var all: [[MessagePart]] = []
    func add(_ parts: [MessagePart]) { all.append(parts) }
}
