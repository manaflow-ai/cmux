import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextDesign
import CoreGraphics
import Foundation
@testable import CmuxNextApp
import CmuxNextChiefPetWiring
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: an optional Chief item in the sidebar (off by default, placed like any item)
/// that tells the truth about the Chief (needs you while a turn waits on a permission, working
/// while one runs, else idle), with its subagents under it. Folded, the list hides only idle
/// subagents, never an active one.
@MainActor
struct ChiefSidebarItemTests {
    static func lane(_ name: String, _ state: AgentActivityLane.State, title: String? = nil) -> AgentActivityLane {
        AgentActivityLane(id: "id-" + name, name: name, title: title ?? name, peer: nil, parent: "optchat-chief:6b68ac4a",
                          state: state, since: nil, error: nil, harness: "claude")
    }

    static func status(_ lanes: [AgentActivityLane]) -> StatusIndicatorState {
        SidebarTransientItem.chiefStatus(lanes: lanes).activity
    }

    static func rows(_ lanes: [AgentActivityLane], showsIdle: Bool = false) -> [SidebarTransientItem] {
        SidebarTransientItem.chiefSubagents(lanes: lanes, showsIdle: showsIdle)
    }

    static let chiefItem = LayoutItem(id: LayoutItemID("itm_chief"), ref: .builtIn(.chief))

    static func placed(_ items: [LayoutItem], transient: [SidebarTransientItem]) -> [String] {
        let model = SidebarModel()
        model.transientTopItems = transient
        let section = LayoutSection(id: LayoutSectionID("sec_top"), showsTitle: false, region: .top, look: .builtIn, items: items)
        return model.placingTransientItems(in: [section]).flatMap(\.items).map(\.id.rawValue)
    }

    @Test func aTurnWaitingOnAPermissionReadsAsNeedsYouOverWorking() {
        #expect(Self.status([Self.lane("optchat-6b68ac4a-190", .working), Self.lane("optchat-6b68ac4a-191", .input)]) == .waiting)
        #expect(Self.status([Self.lane("optchat-6b68ac4a-190", .working)]) == .working)
    }

    @Test func idleWithNoTurnsAndOnlyTheNewestTurnsFailureShows() {
        #expect(Self.status([]) == .idle)
        #expect(Self.status([Self.lane("optchat-6b68ac4a-9", .failed), Self.lane("optchat-6b68ac4a-10", .idle)]) == .idle)
        #expect(Self.status([Self.lane("optchat-6b68ac4a-9", .idle), Self.lane("optchat-6b68ac4a-10", .failed)]) == .error)
    }

    @Test func compactorsAndSubagentsAreNotTheChiefsTurns() {
        let status = SidebarTransientItem.chiefStatus(lanes: [Self.lane("optchat-compact-6b68ac4a-3", .working),
                                                              Self.lane("optchat-sub-6b68ac4a-a2", .input)])
        #expect(status.activity == .idle)
        // The waiting subagent counts on the item instead.
        #expect(status.badge == 1)
    }

    /// acpmux appends `-<m>` to a name already taken (optchat-chief's `is_turn_name`).
    @Test func dedupedSessionNamesKeepTheirRoleAndNumber() {
        #expect(Self.status([Self.lane("optchat-6b68ac4a-191-2", .input)]) == .waiting)
        let rows = Self.rows([Self.lane("optchat-sub-6b68ac4a-a10", .working, title: "Tenth"),
                              Self.lane("optchat-sub-6b68ac4a-a3-2", .working, title: "Third")])
        // Ordered by subagent number; the rows show task titles, never the a3 / a10 ids.
        #expect(rows.map(\.info.title) == ["Third", "Tenth"])
    }

    @Test func theChiefItemCarriesItsStatusAndIsOffByDefault() {
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [Self.chiefItem])])
        let shown = ChiefSidebar.shared.status
        defer { ChiefSidebar.shared.status = shown }
        ChiefSidebar.shared.status = ChiefSidebar.Status(activity: .waiting, badge: 2)
        let info = SidebarBridge.itemInfo(for: layout, registered: { _ in true })[Self.chiefItem.id]
        #expect(info?.activity == .waiting)
        #expect(info?.badge == 2)
        #expect(info?.title == SidebarBuiltIn.chief.title)
        #expect(SidebarBridge.builtInActions[.chief] == "home.openChief")
        #expect(SidebarLayoutDocument.defaults.firstItem(with: .builtIn(.chief)) == nil)
        #expect(ChiefSidebar.menuRemovals(isApp: false, isChief: true) == ["sidebar.item.hideApp"])
        #expect(ChiefSidebar.menuRemovals(isApp: true, isChief: false) == [ChiefSidebar.toggleIdleAction])
    }

    /// The Chief item wears no pet character by default (Lawrence 2026-10-31: "no more default profile
    /// pic thing"): with no upload it keeps its plain glyph whatever character is picked.
    @Test func theChiefItemWearsNoDefaultPicture() {
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [Self.chiefItem])])
        #expect(SidebarBridge.itemInfo(for: layout, registered: { _ in true })[Self.chiefItem.id]?.favicon == nil)
        #expect(ChiefSidebarPictures().favicon(still: nil, image: nil) == nil, "no upload: no picture")
    }

    /// Leo 2026-10-21: the Chief dragged into a group or a machine list is still the Chief there: the list
    /// draws its picture, status and badge (no band holds it).
    @Test func aChiefListedInAGroupKeepsItsLook() throws {
        let shown = ChiefSidebar.shared.status
        defer { ChiefSidebar.shared.status = shown }
        ChiefSidebar.shared.status = ChiefSidebar.Status(activity: .waiting, badge: 2)
        let model = SidebarModel()
        let listed = SidebarListItem(id: "itm_chief", ref: .builtIn(.chief), title: SidebarBuiltIn.chief.title)
        let link = SidebarListItem(id: "itm_link", ref: .url("https://cmux.dev"), title: "cmux")
        model.sections = [SidebarSection(kind: .custom(SidebarCustomSection(id: "sec_pinned")), nodes: [.item(listed), .item(link)])]
        #expect(model.listedBuiltIns.map(\.id) == [Self.chiefItem.id])
        // The Chief's worn picture, as the App hands it over (`ChiefSidebarPictures`).
        let picture = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let info = SidebarBridge.itemInfo(for: SidebarLayoutDocument(sections: []), registered: { _ in true },
                                          chiefFavicon: SidebarFavicon(picture), listed: model.listedBuiltIns)[Self.chiefItem.id]
        #expect(info?.activity == .waiting)
        #expect(info?.badge == 2)
        #expect(info?.favicon != nil)
    }

    /// An unread Chief conversation shows a dot on the item, unless a badge already counts subagents that need you.
    @Test func anUnreadChiefConversationShowsADotWhereNoBadgeCounts() {
        var info = SidebarBuiltIn.chief.defaultInfo
        ChiefSidebar(lanes: AgentLaneStore()).decorate(&info)
        #expect(!info.unreadDot)
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        chief.status = ChiefSidebar.Status(unread: true)
        chief.decorate(&info)
        #expect(info.unreadDot)
        chief.status = ChiefSidebar.Status(activity: .waiting, badge: 1, unread: true)
        chief.decorate(&info)
        #expect(!info.unreadDot)
        #expect(info.badge == 1)
    }

    @Test func foldedHidesOnlyIdleSubagentsInNumberOrder() {
        let lanes = [Self.lane("optchat-sub-6b68ac4a-a10", .working, title: "Inspector"),
                     Self.lane("optchat-sub-6b68ac4a-a2", .idle),
                     Self.lane("optchat-sub-6b68ac4a-a3", .failed)]
        let folded = Self.rows(lanes)
        #expect(folded.map(\.info.title) == ["", "Inspector"], "the a3 id never shows")
        #expect(folded.allSatisfy { $0.info.indent == 1 && $0.anchoredOnly })
        #expect(folded[0].info.activity == .error)
        let open = Self.rows(lanes, showsIdle: true)
        #expect(open.map(\.info.title) == ["", "", "Inspector"])
        #expect(SidebarTransientItem.chiefSubagentSession(open[0].item.id) == "id-optchat-sub-6b68ac4a-a2")
        #expect(SidebarTransientItem.chiefSubagentSession(LayoutItemID("itm_chief")) == nil)
    }

    /// The top row that was Home is the Chief (the person, 2026-11-20: "we replace home with chief"), so the rows
    /// follow it too when the layout has no Chief item.
    @Test func subagentRowsFollowTheChiefItemAndVanishWithoutIt() {
        let rows = Self.rows([Self.lane("optchat-sub-6b68ac4a-a1", .working), Self.lane("optchat-sub-6b68ac4a-a2", .input)])
        let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
        let ids = rows.map(\.item.id.rawValue)
        #expect(Self.placed([Self.chiefItem, home], transient: rows) == ["itm_chief"] + ids + ["itm_home"])
        #expect(Self.placed([home, Self.chiefItem], transient: rows) == ["itm_home", "itm_chief"] + ids)
        #expect(Self.placed([home], transient: rows) == ["itm_home"] + ids)
        let store = LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))
        #expect(Self.placed([store], transient: rows) == ["itm_app_store"], "rows drew with no Chief row to follow")
    }
    /// Home learns which of the Chief's agents started from these lanes (a1019, 2026-11-06: a queued agent that
    /// started with no word in the chat still said Queued). The list names each subagent by its Chief id, and
    /// changes when a subagent's session comes or goes, never on a step of its output.
    @Test func theChiefsLanesNameItsStartedAgentsAndChangeOnlyWhenOneComesOrGoes() {
        let store = AgentLaneStore()
        #expect(store.chiefSubagentPeers.isEmpty)
        store.lanes = ["s1": Self.lane("optchat-sub-6b68ac4a-a1017", .working),
                       "s2": Self.lane("optchat-6b68ac4a-190", .working),
                       "s3": Self.lane("optchat-sub-6b68ac4a-a3-2", .idle),
                       "s4": Self.lane("optchat-compact-6b68ac4a-1", .working)]
        #expect(store.chiefSubagentPeers == ["a1017", "a3"])
        let names = store.names
        store.set("s1", Self.lane("optchat-sub-6b68ac4a-a1017", .input))
        #expect(store.names == names)
        store.set("s5", Self.lane("optchat-sub-6b68ac4a-a1020", .working))
        #expect(store.chiefSubagentPeers == ["a1017", "a3", "a1020"])
        store.set("s1", nil)
        #expect(store.chiefSubagentPeers == ["a3", "a1020"])
    }

    /// Home's agent pills count from each agent's session start (user 2026-11-20), which the Chief's lanes carry
    /// (`createdAt`, acpmux's `createdMs`). An agent with a newer session (a deduped `-2` name) counts from that
    /// one; a step of its output leaves the starts as they were.
    @Test func theChiefsLanesSayWhenEachStartedAgentsSessionBegan() {
        let store = AgentLaneStore()
        let at = { (seconds: Double) in Date(timeIntervalSince1970: 50_000 + seconds) }
        func lane(_ name: String, _ state: AgentActivityLane.State, created: Date?) -> AgentActivityLane {
            AgentActivityLane(id: "id-" + name, name: name, title: name, peer: nil, parent: "optchat-chief:6b68ac4a",
                              state: state, since: nil, error: nil, harness: "claude", createdAt: created)
        }
        store.lanes = ["s1": lane("optchat-sub-6b68ac4a-a1017", .working, created: at(10)),
                       "s2": lane("optchat-6b68ac4a-190", .working, created: at(1)),
                       "s3": lane("optchat-sub-6b68ac4a-a3", .idle, created: at(20)),
                       "s4": lane("optchat-sub-6b68ac4a-a3-2", .working, created: at(90)),
                       "s5": lane("optchat-sub-6b68ac4a-a9", .working, created: nil)]
        #expect(store.chiefSubagentStarts == ["a1017": at(10), "a3": at(90)])
        let starts = store.sessionStarts
        store.set("s1", lane("optchat-sub-6b68ac4a-a1017", .input, created: at(10)))
        #expect(store.sessionStarts == starts)
        // A start that arrives after its session's first lane is taken.
        store.set("s5", lane("optchat-sub-6b68ac4a-a9", .working, created: at(120)))
        #expect(store.chiefSubagentStarts == ["a1017": at(10), "a3": at(90), "a9": at(120)])
    }
}
