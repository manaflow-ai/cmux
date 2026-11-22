import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-10: "changing spaces in sidebar also feels kinda slow". With the sidebar document, the list
/// draws the space's top blocks (Home, its pinned workspaces) with its rows. A space switch laid the list out
/// with the new space's rows and the OLD space's blocks, and gave it the new blocks only at the next layout pass,
/// as a second change of the list: a second full layout that moved every row (on a spring after a click), or one
/// that waited for the pointer to leave the rows (a switch by key with the pointer at rest over the sidebar).
/// A switch now lays the list out once, with the rows and the blocks of its space.
@MainActor
struct SidebarSpaceSwitchBlocksTests {
    static let spaces = ["space0", "space1"]
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)

    static func pin(_ space: String) -> LayoutItem { LayoutItem(id: LayoutItemID("itm_pin_\(space)"), ref: .workspace("local:\(space)-pin")) }
    static func pinned(_ space: String) -> LayoutSection {
        LayoutSection(id: LayoutSectionID("sec_pinned_\(space)"), region: .top, look: .builtIn, arrangement: .list, room: space, items: [pin(space)])
    }

    static let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])

    /// The rows of `space`, as the app's rows pass gives them: its document sections, then its workspaces.
    static func sections(_ space: String) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned(space).id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: (0..<40).map { .workspace(SidebarWorkspace(id: WorkspaceID("\(space)-\($0)"), title: "\(space) \($0)")) }),
        ]
    }

    /// A sidebar on "space0" that has drawn and laid out, as a window's has before any switch.
    static func sidebar() -> (SidebarModel, SidebarView) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(spaces[0]), activeWorkspaceID: nil)
        model.profiles = spaces.map { SidebarProfile(id: ProfileKey($0), name: $0) }
        model.activeProfileID = ProfileKey(spaces[0])
        model.layout = SidebarLayoutDocument(sections: [top] + spaces.map(pinned))
        var infos: [LayoutItemID: SidebarItemInfo] = [home.id: SidebarItemInfo(title: "Home", symbol: "house")]
        for space in spaces {
            var info = SidebarItemInfo(title: "Pinned in \(space)", symbol: "textformat")
            info.workspace = WorkspaceID("\(space)-pin")
            infos[pin(space).id] = info
        }
        model.itemInfo = infos
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    /// Whether a block of the list draws `space`'s pinned item.
    static func drawsPin(of space: String, in sidebar: SidebarView) -> Bool {
        sidebar.list.blockRegions.contains { $0.itemView(pin(space).id) != nil }
    }

    @Test func theSidebarStartsWithItsSpacesBlock() {
        let (_, sidebar) = Self.sidebar()
        #expect(Self.drawsPin(of: "space0", in: sidebar), "the fixture's list draws no pinned block")
        #expect(!Self.drawsPin(of: "space1", in: sidebar))
    }

    /// The switch's own list layout has the new space's blocks: no layout pass after it changes the list again.
    @Test func aSwitchLaysTheListOutOnceWithTheNewSpacesBlocks() throws {
        let (model, sidebar) = Self.sidebar()
        try #require(Self.drawsPin(of: "space0", in: sidebar))
        _ = SidebarPerfCounters.report(reset: true)
        model.sections = Self.sections("space1")
        model.activeProfileID = ProfileKey("space1")
        sidebar.renderNow()
        // No layout pass since the switch: this is what the switch's own list layout drew.
        #expect(sidebar.list.displayed.rows.contains { $0.key == .workspace(WorkspaceID("space1-0")) })
        #expect(Self.drawsPin(of: "space1", in: sidebar), "the switch laid the list out without its space's pinned block")
        #expect(!Self.drawsPin(of: "space0", in: sidebar), "the switch laid the list out with the old space's pinned block")
        let own = SidebarPerfCounters.report(reset: true)["list_reloads"] ?? 0
        #expect(own == 1, "the switch laid the list out \(own) times")
        sidebar.layoutSubtreeIfNeeded()
        let later = SidebarPerfCounters.report(reset: true)["list_reloads"] ?? 0
        #expect(later == 0, "the layout pass after the switch laid the list out again (\(later)): the blocks came after the rows")
        #expect(Self.drawsPin(of: "space1", in: sidebar) && !Self.drawsPin(of: "space0", in: sidebar))
    }
}
