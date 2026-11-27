import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import Testing

/// A pinned workspace's status or progress draws on its tile in place: no list layout. Each report changed the
/// blocks' item infos, and the list laid out every row again (`list_reloads`). In the CMUX NEXT Stable
/// `sidebar.400.ticking` bench, whose first workspace is pinned and ticking, that was about 4 full layouts of 400
/// rows a second. A change that moves or resizes a block still lays the list out.
@MainActor
struct SidebarPinnedTileStatusInPlaceTests {
    static let space = "space0"
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let pin = LayoutItem(id: LayoutItemID("itm_pin"), ref: .workspace("local:ticker"))
    static let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
    static let pinned = LayoutSection(id: LayoutSectionID("sec_pinned"), region: .top, look: .builtIn, arrangement: .list, room: space, items: [pin])

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: (0..<40).map { .workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "Workspace \($0)")) }),
        ]
    }

    static func pinInfo(_ activity: StatusIndicatorState) -> SidebarItemInfo {
        var info = SidebarItemInfo(title: "Ticker", symbol: "textformat")
        info.workspace = WorkspaceID("ticker")
        info.activity = activity
        return info
    }

    /// A sidebar that has drawn and laid out its Home and pinned blocks and its rows.
    static func sidebar() -> (SidebarModel, SidebarView) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(), activeWorkspaceID: nil)
        model.profiles = [SidebarProfile(id: ProfileKey(space), name: space)]
        model.activeProfileID = ProfileKey(space)
        model.layout = SidebarLayoutDocument(sections: [top, pinned])
        model.itemInfo = [home.id: SidebarItemInfo(title: "Home", symbol: "house"), pin.id: pinInfo(.idle)]
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

    /// The pinned item's view in the list's blocks.
    static func pinView(_ sidebar: SidebarView) -> SidebarItemRowView? {
        sidebar.list.blockRegions.lazy.compactMap { $0.itemView(pin.id) }.first
    }

    /// Shows a change of the model as the app does: the observation, then the layout pass.
    static func show(_ sidebar: SidebarView) {
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
    }

    @Test func aPinnedWorkspacesProgressDrawsOnItsTileWithNoListLayout() throws {
        let (model, sidebar) = Self.sidebar()
        try #require(Self.pinView(sidebar) != nil, "the fixture's list draws no pinned block")
        _ = SidebarPerfCounters.report(reset: true)
        for progress in [0.25, 0.5, 0.75] {
            model.itemInfo[Self.pin.id] = Self.pinInfo(.busy(progress: progress))
            Self.show(sidebar)
        }
        let counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 0, "3 progress reports laid the list out \(counts["list_reloads"] ?? 0) times")
        #expect(counts["block_patches"] == 3, "3 progress reports drew the blocks in place \(counts["block_patches"] ?? 0) times")
        #expect(Self.pinView(sidebar)?.info.activity == .busy(progress: 0.75), "the tile does not show the last progress")
        #expect(sidebar.list.displayed.rows.contains { $0.key == .workspace(WorkspaceID("ws-0")) })
    }

    @Test func aPinnedItemHiddenStillLaysTheListOut() throws {
        let (model, sidebar) = Self.sidebar()
        try #require(Self.pinView(sidebar) != nil, "the fixture's list draws no pinned block")
        _ = SidebarPerfCounters.report(reset: true)
        var info = Self.pinInfo(.idle)
        info.isHidden = true
        model.itemInfo[Self.pin.id] = info
        Self.show(sidebar)
        let counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 1, "hiding the pinned item laid the list out \(counts["list_reloads"] ?? 0) times")
        #expect(counts["block_patches"] == 0)
        #expect(Self.pinView(sidebar) == nil, "the hidden pinned item still draws")
    }
}
