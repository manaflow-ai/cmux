import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." The band
/// above the list (Pinned without the sidebar document, the remote machines' chats) gave every item a view: 10,000
/// pinned items made 10,000 views. It is registered with the visible-rows contract (`VisibleRowsContract`) at 100 and
/// 10,000 items; an inline section measures a label once while its text stays.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct SidebarBandWindowingTests {
    @Test func sidebarPinnedBand() async throws {
        try await VisibleRowsContract.check(SidebarPinnedBandRows.self)
    }

    /// A fixed 512-entry cache emptied itself inside every layout of a longer inline section, which then measured every
    /// label on every pass.
    @Test(arguments: [100, 10_000])
    func anInlineSectionMeasuresOnlyAChangedLabel(_ count: Int) {
        let ids = (0..<count).map { LayoutItemID("itm_chip_\(count)_\($0)") }
        let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, arrangement: .inline,
                                    items: ids.map { LayoutItem(id: $0, ref: .url("https://example.com/\($0.rawValue)")) })
        var content = SidebarRegionView.Content(sections: [section], infos: Dictionary(uniqueKeysWithValues: ids.map {
            ($0, SidebarItemInfo(title: "Chip \($0.rawValue)", symbol: "link"))
        }), collapsed: [], look: SidebarSectionTunables.currentLook, metrics: .standard, drawsLines: false)
        let meter = ListWorkMeter()
        _ = SidebarRegionView.layout(of: content, width: 260, meter: meter)
        _ = meter.take()
        _ = SidebarRegionView.layout(of: content, width: 260, meter: meter)
        let again = meter.take().rowsLaidOut
        content.infos[ids[count / 2]]?.title = "Renamed chip"
        _ = SidebarRegionView.layout(of: content, width: 260, meter: meter)
        let changed = meter.take().rowsLaidOut
        print("label-measures n=\(count) again=\(again) oneChanged=\(changed)")
        #expect(again == 0, "the same labels measured again: \(again) of \(count)")
        #expect(changed == 1, "one changed label measured \(changed) of \(count)")
    }
}

/// The band above the workspace list: `rows` pinned workspaces (no sidebar document) in a 260 x 900 window.
@MainActor final class SidebarPinnedBandRows: VisibleRowsFixture {
    static let name = "sidebar pinned band"
    let model: SidebarModel
    let sidebar: SidebarView
    let window: NSWindow
    let ids: [LayoutItemID]
    var list: SidebarRegionView { sidebar.aboveRegion }
    var clip: NSClipView { sidebar.aboveScroll.contentView }

    init(rows: Int) async throws {
        _ = NSApplication.shared
        ids = (0..<rows).map { LayoutItemID("itm_band_\($0)") }
        let pinned = LayoutSection(id: SidebarLayoutDocument.pinnedSectionID, region: .top, look: .builtIn, arrangement: .list,
                                   items: ids.map { LayoutItem(id: $0, ref: .workspace("s:\($0.rawValue)")) })
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-1"), title: "One"))])])
        model.layout = SidebarLayoutDocument(sections: [pinned])
        model.itemInfo = Dictionary(uniqueKeysWithValues: ids.map { id in
            var info = SidebarItemInfo(title: id.rawValue, symbol: "terminal")
            info.workspace = WorkspaceID("ws-\(id.rawValue)")
            return (id, info)
        })
        sidebar = SidebarView(model: model, design: DesignSettings())
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        window.orderFrontRegardless()
        sidebar.renderNow()
        await relayout()
        let items = list.layoutResult.rows.filter { Self.isItem($0) }.count
        try #require(items == rows, "the band laid out \(items) of \(rows) items")
        try #require(clip.bounds.height > 0 && clip.bounds.height < list.frame.height, "the band does not scroll")
    }

    /// The bands take a model change at the sidebar's next layout, as a display frame runs it.
    func relayout() async {
        for _ in 0..<5 { await Task.yield() }
        sidebar.bandsDirty = true
        sidebar.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    var viewportRows: Int {
        let visible = list.convert(clip.bounds, from: clip)
        return list.layoutResult.rows.filter { Self.isItem($0) && $0.frame.intersects(visible) }.count
    }

    /// A shown pinned workspace is renamed.
    func changeOneItem() async throws {
        let shown = try #require(ids.first { list.itemView($0) != nil })
        model.itemInfo[shown]?.title = "Renamed"
        await relayout()
        #expect(list.itemView(shown)?.info.title == "Renamed")
    }

    /// From the middle of the band (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let maxY = max(0, list.frame.height - clip.bounds.height)
        guard maxY > 0, let row = list.layoutResult.rows.first(where: { Self.isItem($0) }) else { return false }
        scroll(to: min(maxY / 2, 2_000))
        _ = list.listWork.take()
        scroll(to: clip.bounds.minY + row.frame.height)
        return true
    }

    private func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        sidebar.aboveScroll.reflectScrolledClipView(clip)
        window.displayIfNeeded()
    }

    /// One live-resize step of the window: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 252, height: 900))
        await relayout()
        return true
    }

    func close() { window.close() }

    static func isItem(_ row: SidebarRegionRow) -> Bool {
        switch row.kind {
        case .item, .tile, .chip: true
        case .header, .app: false
        }
    }
}
