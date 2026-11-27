import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// A pinned workspace's status or progress draws on its tile in place: no list layout. Each report changed the
/// blocks' item infos, and the list laid out every row again (`list_reloads`). In the CMUX NEXT Stable
/// `sidebar.400.ticking` bench, whose first workspace is pinned and ticking, that was about 4 full layouts of 400
/// rows a second. A change that moves or resizes a block, or one held under the pointer, still lays the list out.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarPinnedTileStatusInPlaceTests {
    static let space = "space0"
    static let pinnedID = "sec_pinned"
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let pin = LayoutItem(id: LayoutItemID("itm_pin"), ref: .workspace("local:ticker"))
    static let other = LayoutItem(id: LayoutItemID("itm_other"), ref: .workspace("local:other"))
    static let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])

    static func pinned(_ items: [LayoutItem], _ arrangement: SectionArrangement = .list) -> LayoutSection {
        LayoutSection(id: LayoutSectionID(pinnedID), region: .top, look: .builtIn, arrangement: arrangement, room: space, items: items)
    }

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinnedID)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: (0..<40).map { .workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "Workspace \($0)")) }),
        ]
    }

    static func info(_ title: String, workspace: String, _ activity: StatusIndicatorState = .idle) -> SidebarItemInfo {
        var info = SidebarItemInfo(title: title, symbol: "textformat")
        info.workspace = WorkspaceID(workspace)
        info.activity = activity
        return info
    }

    static func pinInfo(_ activity: StatusIndicatorState, title: String = "Ticker") -> SidebarItemInfo {
        info(title, workspace: "ticker", activity)
    }

    /// A sidebar that has drawn and laid out its Home and pinned blocks and its rows; `window` puts it in one.
    static func sidebar(pinned section: LayoutSection = pinned([pin]), window: Bool = false) -> (SidebarModel, SidebarView) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(), activeWorkspaceID: nil)
        model.profiles = [SidebarProfile(id: ProfileKey(space), name: space)]
        model.activeProfileID = ProfileKey(space)
        model.layout = SidebarLayoutDocument(sections: [top, section])
        model.itemInfo = [home.id: SidebarItemInfo(title: "Home", symbol: "house"), pin.id: pinInfo(.idle),
                          other.id: info("Other", workspace: "other")]
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        if window {
            let host = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = sidebar
        }
        sidebar.renderNow()
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    static func pinView(_ sidebar: SidebarView) -> SidebarItemRowView? {
        sidebar.list.blockRegions.lazy.compactMap { $0.itemView(pin.id) }.first
    }

    static func blockRow(_ sidebar: SidebarView) -> SidebarBlockRowView? {
        sidebar.list.rowViews[.block(pinnedID)] as? SidebarBlockRowView
    }

    /// Shows a change of the model as the app does: the observation, then the layout pass.
    static func show(_ sidebar: SidebarView) {
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
    }

    @Test func aPinnedWorkspacesProgressDrawsOnItsTileWithNoListLayout() throws {
        let (model, sidebar) = Self.sidebar()
        try #require(Self.pinView(sidebar) != nil, "the fixture's list draws no pinned block")
        let blockFrame = Self.blockRow(sidebar)?.frame
        let rowFrame = sidebar.list.rowViews[.workspace(WorkspaceID("ws-0"))]?.frame
        _ = SidebarPerfCounters.report(reset: true)
        for progress in [0.25, 0.5, 0.75] {
            model.itemInfo[Self.pin.id] = Self.pinInfo(.busy(progress: progress))
            Self.show(sidebar)
        }
        let counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 0, "3 progress reports laid the list out \(counts["list_reloads"] ?? 0) times")
        #expect(counts["block_patches"] == 3, "3 progress reports drew the blocks in place \(counts["block_patches"] ?? 0) times")
        #expect(Self.pinView(sidebar)?.info.activity == .busy(progress: 0.75), "the tile does not show the last progress")
        // Nothing moved: the block and the first row under it keep their frames, and the block fills its row.
        #expect(Self.blockRow(sidebar)?.frame == blockFrame)
        #expect(sidebar.list.rowViews[.workspace(WorkspaceID("ws-0"))]?.frame == rowFrame)
        if let row = Self.blockRow(sidebar) { #expect(row.region.frame.height == row.frame.height) }
    }

    @Test func aPinnedItemHiddenStillLaysTheListOut() throws {
        let (model, sidebar) = Self.sidebar()
        try #require(Self.pinView(sidebar) != nil, "the fixture's list draws no pinned block")
        _ = SidebarPerfCounters.report(reset: true)
        var hidden = Self.pinInfo(.idle)
        hidden.isHidden = true
        model.itemInfo[Self.pin.id] = hidden
        Self.show(sidebar)
        let counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 1, "hiding the pinned item laid the list out \(counts["list_reloads"] ?? 0) times")
        #expect((counts["block_patches"] ?? 0) == 0)
        #expect(Self.pinView(sidebar) == nil, "the hidden pinned item still draws")
    }

    /// In an inline section a longer title widens its chip: a change that keeps the block's height draws in place,
    /// and one that wraps the chip to a new line lays the list out, so the rows under the block make room.
    @Test func aChipThatWrapsLaysTheListOutAndOneThatFitsDoesNot() throws {
        let (model, sidebar) = Self.sidebar(pinned: Self.pinned([Self.other, Self.pin], .inline))
        try #require(Self.pinView(sidebar) != nil, "the fixture's list draws no pinned block")
        var wrapped = false, patched = false
        for length in [2, 4, 8, 16, 32, 64] {
            let before = try #require(sidebar.list.blockHeights(includeGap: true)[Self.pinnedID])
            _ = SidebarPerfCounters.report(reset: true)
            model.itemInfo[Self.pin.id] = Self.pinInfo(.idle, title: String(repeating: "W", count: length))
            Self.show(sidebar)
            let counts = SidebarPerfCounters.report(reset: true)
            let after = sidebar.list.blockHeights(includeGap: true)[Self.pinnedID]
            if after != before {
                wrapped = true
                #expect(counts["list_reloads"] == 1, "a \(length)-letter title moved the block's height and laid the list out \(counts["list_reloads"] ?? 0) times")
                #expect((counts["block_patches"] ?? 0) == 0)
            } else {
                patched = true
                #expect(counts["list_reloads"] == 0, "a \(length)-letter title kept the block's height and laid the list out \(counts["list_reloads"] ?? 0) times")
                #expect(counts["block_patches"] == 1)
            }
            if let row = Self.blockRow(sidebar) { #expect(row.region.frame.height == row.frame.height, "the block spills out of its row") }
        }
        #expect(wrapped, "fixture: no title wrapped the chip to a new line")
        #expect(patched, "fixture: every title changed the block's height")
    }

    /// A change held while the pointer is over the rows (an item added to Pinned) leaves the shown layout older than
    /// the blocks: a tick then waits with it, so the block never draws a height its row was not given.
    @Test func aTickUnderAHeldChangeWaitsWithIt() throws {
        let (model, sidebar) = Self.sidebar(window: true)
        defer { sidebar.window?.close() }
        try #require(Self.pinView(sidebar) != nil, "the fixture's list draws no pinned block")
        sidebar.list.pointerIsOverList = { _ in true }
        _ = SidebarPerfCounters.report(reset: true)
        model.layout = SidebarLayoutDocument(sections: [Self.top, Self.pinned([Self.pin, Self.other])])
        Self.show(sidebar)
        try #require(sidebar.list.holdsModelChange, "fixture: the added item did not wait for the pointer")
        model.itemInfo[Self.pin.id] = Self.pinInfo(.busy(progress: 0.5))
        Self.show(sidebar)
        var counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 0, "the held change showed under the pointer")
        #expect((counts["block_patches"] ?? 0) == 0, "the tick drew the blocks over a layout that does not have them")
        if let row = Self.blockRow(sidebar) { #expect(row.region.frame.height == row.frame.height, "the block spills out of its row") }
        // The pointer leaves: one layout shows the added item and the tick.
        sidebar.list.pointerIsOverList = { _ in false }
        sidebar.list.releaseHeldModelChangeIfPointerLeft()
        counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 1)
        #expect(Self.pinView(sidebar)?.info.activity == .busy(progress: 0.5))
        #expect(sidebar.list.blockRegions.contains { $0.itemView(Self.other.id) != nil }, "the added item does not draw")
        if let row = Self.blockRow(sidebar) { #expect(row.region.frame.height == row.frame.height) }
    }
}
