import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextHostedChief
@testable import MessagesLabSidebar
import Testing

/// One main Chief, its hosts merged, and host switching in the Chief's card
/// (Lawrence 2026-10-19: "very confused by this segmented control, i dont
/// like" and "i dont like that i have a ton of chiefs, idk which is main one").
@MainActor
struct HomeChiefRosterTests {
    static let me = ParticipantID("me")
    static let local = CmuxHomeCore.ConversationID("conv_local")
    static let hosted = CmuxHomeCore.ConversationID("conv_hosted")
    static let placed = CmuxHomeCore.ConversationID("conv_placed")
    static let unii = CmuxHomeCore.ConversationID("conv_unii")
    static let ada = CmuxHomeCore.ConversationID("conv_ada")

    /// The rows the user has today: this Mac's Chief, the Hosted Chief, the
    /// Chief on the Mac mini (all named "Chief"), Unii, and a DM.
    static var rows: [InboxRow] {
        [chief(local, "agent_mux", "Chief", at: 5), chief(hosted, "chief_hosted", "Chief", at: 4),
         chief(placed, "chief_placed", "Chief", at: 3), chief(unii, "agent_unii", "Unii", at: 2), dm(ada, at: 1)]
    }

    static func roster(showsPlaced: Bool = false) -> HomeChiefRoster {
        HomeChiefRoster.make(rows: rows, local: local, hosted: hosted, placed: placed, server: "cmux20", showsPlaced: showsPlaced)
    }

    @Test func oneMainChiefLeadsAndItsOtherHostsAreMerged() {
        let model = HomeSidebarModel(rows: Self.rows, pins: HomePins(), me: Self.me, chiefRoster: Self.roster())
        let listed = (model.pinned + model.rows).map(\.id)
        #expect(listed.filter { [Self.local, Self.hosted, Self.placed].contains($0) } == [Self.hosted],
                "the same Chief on three hosts is one entry")
        #expect(model.pinned.first?.id == Self.hosted, "the main Chief is pinned first")
        #expect(model.pinned.first?.isMainChief == true)
        #expect(model.pinned.first?.listBadge == HomeConversationStrings.mainChief)
        #expect(model.pinned.filter(\.isMainChief).count == 1, "exactly one main Chief")
    }

    @Test func everyOtherChiefSaysWhereItRuns() {
        let model = HomeSidebarModel(rows: Self.rows, pins: HomePins(), me: Self.me, chiefHarnesses: ["agent_unii": "unii"],
                                     chiefRoster: Self.roster())
        guard let unii = model.pinned.first(where: { $0.id == Self.unii }) else { Issue.record("Unii is listed"); return }
        #expect(unii.place == .thisMac)
        #expect(unii.listBadge?.hasPrefix(HomeConversationStrings.placeThisMac) == true)
        #expect(unii.accessibilityLabel.hasPrefix("Unii, " + HomeConversationStrings.placeThisMac))
        // The list draws the tag after the name.
        let entry = HomeSidebarView.entry(unii)
        #expect(entry.shownTitle.hasPrefix("Unii \u{00B7} " + HomeConversationStrings.placeThisMac))
        // A DM gets no tag.
        #expect(model.rows.first { $0.id == Self.ada }?.listBadge == nil)
    }

    @Test func pickingTheServerMakesItTheMainEntryInstead() {
        let roster = Self.roster(showsPlaced: true)
        #expect(roster.main == Self.placed)
        #expect(roster.merged == [Self.hosted, Self.local])
        #expect(roster.places[Self.placed] == .server("cmux20"))
        #expect(roster.places[Self.hosted] == .cloud)
    }

    @Test func withoutAHostedChiefThisMacsChiefStaysItsOwnTaggedEntry() {
        let roster = HomeChiefRoster.make(rows: Self.rows, local: Self.local, hosted: nil, placed: Self.placed, server: "cmux20",
                                          showsPlaced: true)
        #expect(roster.main == Self.placed)
        #expect(!roster.merged.contains(Self.local), "its history was never copied anywhere: hiding it would lose it")
        #expect(roster.tag(for: Self.local, engine: nil) == HomeConversationStrings.placeThisMac)
    }

    // MARK: The host switch lives in the Chief's card

    @Test func theCardOffersTheOtherHostAndSwitches() {
        let card = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: HomeChiefLocalEngine(
            files: HomeChiefFiles(muxHome: FileManager.default.temporaryDirectory), connection: { nil }))
        #expect(card.hostSwitch.isHidden, "a Chief with one host offers no switch")
        var switched = 0
        card.onSwitchHost = { switched += 1 }
        card.setHost(place: HomeEngineStrings.runsInCloud, switchTo: "cmux20")
        #expect(!card.hostSwitch.isHidden)
        #expect(card.place.stringValue == HomeEngineStrings.runsInCloud)
        #expect(card.hostSwitch.title.contains("cmux20"))
        card.hostSwitch.performClick(nil)
        #expect(switched == 1)
        card.setHost(place: nil, switchTo: nil)
        #expect(card.hostSwitch.isHidden)
    }

    @Test func theOtherHostIsOfferedOnlyOnTheChiefsOwnConversations() {
        let chiefs = HomeCloudChiefs(hosted: CloudChief(id: "h", displayName: "Chief", isDefault: true, mainConversation: Self.hosted.rawValue, rev: 1),
                                     placed: CloudChief(id: "p", displayName: "Chief", isDefault: false, mainConversation: Self.placed.rawValue,
                                                        rev: 1, brainPlace: .init(host: "host_1", install: "i")))
        #expect(chiefs.otherHost(of: Self.hosted.rawValue) == .placed)
        #expect(chiefs.otherHost(of: Self.placed.rawValue) == .hosted)
        #expect(chiefs.otherHost(of: Self.unii.rawValue) == nil)
        #expect(HomeCloudChiefs(hosted: chiefs.hosted).otherHost(of: Self.hosted.rawValue) == nil)
    }

    @Test func noSegmentedControlFloatsOverTheChat() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let view = HomeHostView(services: services, conversation: Self.hosted.rawValue)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        view.layoutSubtreeIfNeeded()
        #expect(!Self.descendants(of: view).contains { $0 is NSSegmentedControl })
    }

    // MARK: Fixtures

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    static func chief(_ id: CmuxHomeCore.ConversationID, _ agent: String, _ title: String, at: TimeInterval) -> InboxRow {
        row(id, title: title, participants: [Participant(id: ParticipantID(agent), kind: .agent, displayName: title, agentClass: .chief)], at: at)
    }

    static func dm(_ id: CmuxHomeCore.ConversationID, at: TimeInterval) -> InboxRow {
        row(id, title: "Ada", participants: [Participant(id: ParticipantID("ada"), kind: .human, displayName: "Ada")], at: at)
    }

    static func row(_ id: CmuxHomeCore.ConversationID, title: String, participants: [Participant], at: TimeInterval) -> InboxRow {
        let date = Date(timeIntervalSince1970: 1_000 + at)
        let mine = Participant(id: me, kind: .human, displayName: "Me")
        let summary = ConversationSummary(id: id, title: title, participants: [mine] + participants, createdAt: date, updatedAt: date)
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: mine, conversations: [summary], rev: 1))
        return mirror.inboxRows(log: IntentLog())[0]
    }
}
