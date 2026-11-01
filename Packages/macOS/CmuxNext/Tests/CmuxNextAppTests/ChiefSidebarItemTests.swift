import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextDesign
@testable import CmuxNextApp
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
        func picture(_ mascot: String?) -> SidebarFavicon? {
            SidebarBridge.itemInfo(for: layout, registered: { _ in true }, chiefMascot: mascot)[Self.chiefItem.id]?.favicon
        }
        #expect(picture("fox") == nil)
        #expect(picture(nil) == nil)
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

    @Test func subagentRowsFollowTheChiefItemAndVanishWithoutIt() {
        let rows = Self.rows([Self.lane("optchat-sub-6b68ac4a-a1", .working), Self.lane("optchat-sub-6b68ac4a-a2", .input)])
        let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
        let ids = rows.map(\.item.id.rawValue)
        #expect(Self.placed([Self.chiefItem, home], transient: rows) == ["itm_chief"] + ids + ["itm_home"])
        #expect(Self.placed([home, Self.chiefItem], transient: rows) == ["itm_home", "itm_chief"] + ids)
        #expect(Self.placed([home], transient: rows) == ["itm_home"])
    }
}
