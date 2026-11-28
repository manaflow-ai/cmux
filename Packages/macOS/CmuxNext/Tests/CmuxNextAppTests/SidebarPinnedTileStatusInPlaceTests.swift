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
    /// A custom section of the band above the list: the pinned section always draws rows (`SectionFlow.mode`).
    static let chipsID = "sec_chips"
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let pin = LayoutItem(id: LayoutItemID("itm_pin"), ref: .workspace("local:ticker"))
    static let other = LayoutItem(id: LayoutItemID("itm_other"), ref: .workspace("local:other"))
    static let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])

    static func pinned(_ items: [LayoutItem], _ arrangement: SectionArrangement = .list, id: String = pinnedID) -> LayoutSection {
        LayoutSection(id: LayoutSectionID(id), region: .top, look: .builtIn, arrangement: arrangement, room: space, items: items)
    }

    static func sections(_ section: LayoutSection) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: section.id.rawValue)), nodes: []),
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
        let model = SidebarModel(sections: sections(section), activeWorkspaceID: nil)
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

    static func blockRow(_ sidebar: SidebarView, id: String = pinnedID) -> SidebarBlockRowView? {
        sidebar.list.rowViews[.block(id)] as? SidebarBlockRowView
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

    /// The kind the pinned block's own layout gave the pinned item (a labeled chip or an icon tile), if it placed it.
    static func pinKind(_ sidebar: SidebarView) -> SidebarRegionRow.Kind? {
        blockRow(sidebar, id: chipsID)?.region.layoutResult.rows.first { row in
            switch row.kind {
            case let .chip(id, _), let .tile(id, _): id == pin.id
            default: false
            }
        }?.kind
    }

    /// In an inline section a title too long for one line turns every chip into an icon tile, at the same height
    /// (`SectionFlow`'s inline placement never wraps a label): that draws in place, the block placing its own items
    /// again, and a title that fits brings the chips back. The list's rows keep their frames throughout.
    @Test func aTitleTooLongForTheLineTurnsTheChipsIntoTilesInPlace() throws {
        let (model, sidebar) = Self.sidebar(pinned: Self.pinned([Self.other, Self.pin], .inline, id: Self.chipsID))
        let section = LayoutSectionID(Self.chipsID)
        try #require(Self.pinKind(sidebar) == .chip(Self.pin.id, section: section), "fixture: the short title draws no chip")
        let blockFrame = Self.blockRow(sidebar, id: Self.chipsID)?.frame
        let rowFrame = sidebar.list.rowViews[.workspace(WorkspaceID("ws-0"))]?.frame
        for (title, kind) in [(String(repeating: "W", count: 64), SidebarRegionRow.Kind.tile(Self.pin.id, section: section)),
                              ("Ticker", .chip(Self.pin.id, section: section))] {
            _ = SidebarPerfCounters.report(reset: true)
            model.itemInfo[Self.pin.id] = Self.pinInfo(.idle, title: title)
            Self.show(sidebar)
            let counts = SidebarPerfCounters.report(reset: true)
            #expect(counts["list_reloads"] == 0, "a \(title.count)-letter title laid the list out \(counts["list_reloads"] ?? 0) times")
            #expect(counts["block_patches"] == 1, "a \(title.count)-letter title drew the blocks in place \(counts["block_patches"] ?? 0) times")
            #expect(Self.pinKind(sidebar) == kind, "a \(title.count)-letter title placed the pinned item as \(String(describing: Self.pinKind(sidebar)))")
            #expect(Self.pinView(sidebar)?.info.title == title, "the pinned item does not show its new title")
            #expect(Self.blockRow(sidebar, id: Self.chipsID)?.frame == blockFrame)
            #expect(sidebar.list.rowViews[.workspace(WorkspaceID("ws-0"))]?.frame == rowFrame)
            if let row = Self.blockRow(sidebar, id: Self.chipsID) { #expect(row.region.frame.height == row.frame.height, "the block spills out of its row") }
        }
    }

    /// Under the pointer (calm-sidebar-movement): a change nobody asked for that moves an item in a block (a chip turned
    /// into a tile) waits for the pointer to leave, as its layout would; one the user asked for draws now.
    @Test func underThePointerAChangeThatMovesAChipWaitsUnlessTheUserAskedForIt() throws {
        let (model, sidebar) = Self.sidebar(pinned: Self.pinned([Self.other, Self.pin], .inline, id: Self.chipsID), window: true)
        defer { sidebar.window?.close() }
        let section = LayoutSectionID(Self.chipsID)
        try #require(Self.pinKind(sidebar) == .chip(Self.pin.id, section: section), "fixture: the short title draws no chip")
        sidebar.list.pointerIsOverList = { _ in true }
        _ = SidebarPerfCounters.report(reset: true)
        model.itemInfo[Self.pin.id] = Self.pinInfo(.idle, title: String(repeating: "W", count: 64))
        Self.show(sidebar)
        var counts = SidebarPerfCounters.report(reset: true)
        #expect((counts["block_patches"] ?? 0) == 0, "the chips moved under the pointer")
        #expect(counts["list_reloads"] == 0)
        #expect(sidebar.list.holdsModelChange, "the change does not wait for the pointer")
        #expect(Self.pinKind(sidebar) == .chip(Self.pin.id, section: section))
        // The pointer leaves: the change shows.
        sidebar.list.pointerIsOverList = { _ in false }
        sidebar.list.releaseHeldModelChangeIfPointerLeft()
        counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 1)
        #expect(Self.pinKind(sidebar) == .tile(Self.pin.id, section: section))
        // The user asked for the next one (a rename from the menu): it draws under the pointer, in place.
        sidebar.list.pointerIsOverList = { _ in true }
        model.noteUserIntent()
        model.itemInfo[Self.pin.id] = Self.pinInfo(.idle, title: "Ticker")
        Self.show(sidebar)
        counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["block_patches"] == 1, "the user's change waited for the pointer")
        #expect(counts["list_reloads"] == 0)
        #expect(Self.pinKind(sidebar) == .chip(Self.pin.id, section: section))
    }

    /// Under the pointer, a pinned workspace's progress moves nothing: it draws on its tile now, with no list layout.
    @Test func underThePointerAPinnedTickDrawsInPlace() throws {
        let (model, sidebar) = Self.sidebar(window: true)
        defer { sidebar.window?.close() }
        try #require(Self.pinView(sidebar) != nil, "the fixture's list draws no pinned block")
        sidebar.list.pointerIsOverList = { _ in true }
        _ = SidebarPerfCounters.report(reset: true)
        model.itemInfo[Self.pin.id] = Self.pinInfo(.busy(progress: 0.5))
        Self.show(sidebar)
        let counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["block_patches"] == 1)
        #expect(counts["list_reloads"] == 0)
        #expect(!sidebar.list.holdsModelChange)
        #expect(Self.pinView(sidebar)?.info.activity == .busy(progress: 0.5))
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
