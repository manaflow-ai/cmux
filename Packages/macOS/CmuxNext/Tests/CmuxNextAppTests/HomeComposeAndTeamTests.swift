import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing

/// The user, 2026-10-21: "for compose button default should make it look like imessage, so the
/// compose button is always in the body area not the sidebar, even on big screen sizes. and by
/// default i should be able to see everyone in my team as people i can chat to".
@MainActor
@Suite(.closesItsWindows)
struct HomeComposeAndTeamTests {
    static let me = HomeNewMessageTests.me
    static let ada = HomeNewMessageTests.ada
    static let alan = HomeNewMessageTests.alan
    static let grace = HomeNewMessageTests.grace
    static let chief = HomeNewMessageTests.chief
    static let contacts = HomeNewMessageTests.contacts

    // MARK: Compose sits in the chat at every width

    /// The list's header never holds compose, with names or avatars only, at any list width.
    @Test(arguments: [76, 140, 180, 260, 320, 480, 800] as [CGFloat])
    func theListHeaderHasNoCompose(_ width: CGFloat) {
        let h = HomeSidebarHeaderLayout(width: width, searchOpen: false)
        #expect(h.compose == .zero, "the list holds compose at \(width)")
    }

    /// The chat's round compose button shows at its top-left beside every list width, in a small
    /// and a very large window; the list's own compose stays hidden.
    @Test(arguments: [(1000, 76), (1000, 320), (2560, 320), (2560, 480)] as [(CGFloat, CGFloat)])
    func theChatHoldsComposeAtEveryWidth(_ window: CGFloat, _ list: CGFloat) throws {
        _ = NSApplication.shared
        let suite = "cmux.tests.composeTeam.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        let content = NSView()
        let split = HomeSidebarSplitView(sidebar: home, content: content, widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: window, height: 800), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.contentView = split
        split.layoutSubtreeIfNeeded()
        split.setWidth(list)
        split.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        #expect(home.compose.isHidden, "the list shows compose at \(list) pt in a \(window) pt window")
        let button = try #require(HomeNarrowSidebarTests.chatCompose(in: split))
        #expect(!button.isHidden, "the chat has no compose at \(list) pt in a \(window) pt window")
        let frame = button.convert(button.bounds, to: content)
        #expect(frame.minX >= 4 && frame.minX <= 24)
        split.composing = true
        #expect(button.isHidden)
    }

    // MARK: The team in the list

    /// With no search, every team member the user has no DM with is listed as someone to chat to;
    /// people already in a DM, connections outside the team and Chiefs are not listed twice.
    @Test func teammatesWithoutADMAreListedByDefault() {
        let rows = [HomeNewMessageTests.row("dm-grace", [Self.grace.id]), HomeNewMessageTests.row("chief", [Self.chief.id])]
        let model = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me, contacts: Self.contacts)
        #expect(model.teammates == [Self.ada])
        let searched = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me, query: "ada", contacts: Self.contacts)
        #expect(searched.teammates.isEmpty, "the search lists teammates in its own section")
        #expect(searched.people == [Self.ada])
    }

    /// The user, 2026-10-29: "there are 2 austins now?". The cmux team holds two accounts of one
    /// person (Austin Wang, a work and a personal sign-in): the list had his DM and a teammate row
    /// for his other account, and choosing that row made a second, empty Austin DM. One name is one
    /// person in the list: a teammate named like a DM peer, or like a teammate listed already, gets
    /// no row of its own (New Message's search still finds each account).
    @Test func aNameAlreadyListedGetsNoSecondTeammateRow() {
        let work = HomeContact(id: ParticipantID("austin-work"), name: "Austin Wang", source: .team)
        let personal = HomeContact(id: ParticipantID("austin-personal"), name: "Austin Wang", source: .team)
        let dm = HomeNewMessageTests.row("dm-austin", participants: [Participant(id: work.id, kind: .human, displayName: "Austin Wang")])
        let withDM = HomeSidebarModel(rows: [dm], pins: HomePins(), me: Self.me, contacts: [work, personal, Self.ada])
        #expect(withDM.teammates == [Self.ada])
        let noDM = HomeSidebarModel(rows: [], pins: HomePins(), me: Self.me, contacts: [work, personal, Self.ada])
        #expect(noDM.teammates == [work, Self.ada])
        let searched = HomeSidebarModel(rows: [dm], pins: HomePins(), me: Self.me, query: "austin", contacts: [work, personal])
        #expect(searched.people == [personal], "the search reaches the other account")
    }

    /// The list draws each teammate as a row after the conversations; choosing it starts the DM
    /// and never reports a conversation selection.
    @Test func aTeammateRowStartsTheDM() throws {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let rows = [HomeNewMessageTests.row("dm-grace", [Self.grace.id])]
        home.update(HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me, contacts: Self.contacts))
        let ids = home.list.entries.map(\.id)
        let teammate = HomeSidebarView.teammateRowID(Self.ada)
        #expect(ids == ["dm-grace", teammate])
        let entry = try #require(home.list.entries.last)
        #expect(entry.title == "Ada Lovelace")
        var selected: [CmuxHomeCore.ConversationID] = []
        var started: [HomeContact] = []
        home.onSelect = { selected.append($0) }
        home.onOpen = { selected.append($0) }
        home.onStartTeammate = { started.append($0) }
        home.list.onSelect(teammate)
        home.list.onOpen(teammate)
        #expect(started == [Self.ada])
        #expect(selected.isEmpty)
    }

    // MARK: The team in New Message's To: field

    /// Before anything is typed, To: offers the Chiefs, then every team member not chosen yet.
    @Test func theToFieldOffersTheTeamBeforeTyping() {
        var draft = HomeNewMessageDraft()
        #expect(draft.idleSuggestions(contacts: Self.contacts) == [Self.chief, Self.ada, Self.grace])
        draft.query = "Ada Lovelace"
        draft.commit(contacts: Self.contacts)
        #expect(draft.idleSuggestions(contacts: Self.contacts) == [Self.chief, Self.grace])
    }
}
