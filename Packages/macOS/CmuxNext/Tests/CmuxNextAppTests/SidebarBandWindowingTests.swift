import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-18: "we draw the visible area, right? Like, that's what we're supposed to do." A band above the list
/// (Pinned with no sidebar document, the remote machines' chats) gave every item a view: 10,000 pinned items made
/// 10,000 views. It now makes the items its scroll view shows and the list's overscan, at 100 items as at 10,000; one
/// changed item configures one view, one scroll step only the items it brings in, a selection change the old and new
/// item. An inline section measures a label once while its text stays (a fixed 512-entry cache emptied inside every
/// layout of a longer one, which then measured every label on every pass).
///
/// The counters are process-wide: every phase runs in one main-actor turn (no await between its reset and its read),
/// so no other suite's sidebar renders inside it.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarBandWindowingTests {
    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let ids: [LayoutItemID]
        var region: SidebarRegionView { sidebar.aboveRegion }
        var clip: NSClipView { sidebar.aboveScroll.contentView }

        init(_ count: Int) {
            _ = NSApplication.shared
            ids = (0..<count).map { LayoutItemID("itm_band_\($0)") }
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
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = sidebar
            window.orderFrontRegardless()
            sidebar.renderNow()
            relayout()
        }

        /// Lays the bands out again from the model now (what the sidebar's layout does after a model change).
        func relayout() {
            sidebar.bandsDirty = true
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }

        /// The shortest item row: the most items one point of the band can hold.
        var rowHeight: CGFloat {
            region.layoutResult.rows.filter { if case .item = $0.kind { true } else { false } }.map(\.frame.height).min() ?? 1
        }

        /// The most item views the band may hold: the rows its clip shows, the overscan past each edge and the prune margin.
        var bound: Int {
            Int(((clip.bounds.height + (SidebarStyle.overscan + SidebarStyle.pruneMargin) * 2) / rowHeight).rounded(.up)) + 2
        }
    }

    /// The counters since the last call.
    static func counts() -> (made: Int, configures: Int, measures: Int) {
        let r = SidebarPerfCounters.report(reset: true)
        return (r["item_views_made"] ?? 0, r["item_configures"] ?? 0, r["label_measures"] ?? 0)
    }

    @Test(arguments: [100, 10_000])
    func aBandMakesOnlyTheItemsItShows(_ count: Int) throws {
        let h = Harness(count)
        defer { h.window.closeAfterTest() }
        let items = h.region.layoutResult.rows.filter { if case .item = $0.kind { true } else { false } }.count
        try #require(items == count, "the band laid out \(items) of \(count) items")
        try #require(h.clip.bounds.height > 0 && h.clip.bounds.height < h.region.frame.height,
                     "the band does not scroll: clip \(h.clip.bounds.height), content \(h.region.frame.height)")
        let bound = h.bound
        // The band as it was: the same content in a region with no item window, which gives every item a view.
        _ = Self.counts()
        let eager = SidebarRegionView(region: .top)
        eager.update(try #require(h.region.content), width: h.region.bounds.width)
        print("band-windowing n=\(count) mounted=\(h.region.itemViews.count) bound=\(bound) clip=\(h.clip.bounds.height) "
              + "unwindowed=\(eager.itemViews.count) unwindowedMade=\(Self.counts().made)")
        #expect(h.region.itemViews.count <= bound, "\(h.region.itemViews.count) item views for \(count) items (bound \(bound))")

        // One changed item configures its view alone.
        let changed = try #require(h.ids.first { h.region.itemView($0) != nil })
        _ = Self.counts()
        h.model.itemInfo[changed]?.title = "Renamed"
        h.relayout()
        let change = Self.counts()
        print("band-windowing n=\(count) change=\(change)")
        #expect(h.region.itemView(changed)?.info.title == "Renamed")
        #expect(change.configures == 1 && change.made == 0, "one changed item: \(change)")

        // One scroll step configures only the items it brings in.
        _ = Self.counts()
        h.clip.scroll(to: NSPoint(x: 0, y: h.rowHeight))
        h.sidebar.aboveScroll.reflectScrolledClipView(h.clip)
        let step = Self.counts()
        print("band-windowing n=\(count) scrollStep=\(step) mounted=\(h.region.itemViews.count)")
        #expect(step.made <= 2 && step.configures == step.made, "one scroll step: \(step)")
        #expect(h.region.itemViews.count <= bound)

        // A selection change configures the old and the new item.
        let shown = h.ids.filter { h.region.itemView($0) != nil }
        try #require(shown.count >= 3)
        h.region.activeItem = shown[1]
        _ = Self.counts()
        h.region.activeItem = shown[2]
        let selection = Self.counts()
        #expect(selection.configures == 2 && selection.made == 0, "a selection change: \(selection)")

        // The far end of the band: its last items have views, and still no more than it shows.
        _ = Self.counts()
        h.clip.scroll(to: NSPoint(x: 0, y: h.region.frame.height - h.clip.bounds.height))
        h.sidebar.aboveScroll.reflectScrolledClipView(h.clip)
        let end = Self.counts()
        print("band-windowing n=\(count) scrollToEnd=\(end) mounted=\(h.region.itemViews.count)")
        #expect(h.region.itemView(try #require(h.ids.last)) != nil, "the band's last item has no view at its end")
        #expect(h.region.itemViews.count <= bound, "\(h.region.itemViews.count) item views at the end (bound \(bound))")
    }

    @Test(arguments: [100, 10_000])
    func anInlineSectionMeasuresOnlyAChangedLabel(_ count: Int) throws {
        let ids = (0..<count).map { LayoutItemID("itm_chip_\(count)_\($0)") }
        let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, arrangement: .inline,
                                    items: ids.map { LayoutItem(id: $0, ref: .url("https://example.com/\($0.rawValue)")) })
        var content = SidebarRegionView.Content(sections: [section], infos: Dictionary(uniqueKeysWithValues: ids.map {
            ($0, SidebarItemInfo(title: "Chip \($0.rawValue)", symbol: "link"))
        }), collapsed: [], look: SidebarSectionTunables.currentLook, metrics: .standard, drawsLines: false)
        _ = SidebarRegionView.layout(of: content, width: 260)
        _ = Self.counts()
        _ = SidebarRegionView.layout(of: content, width: 260)
        let again = Self.counts()
        content.infos[ids[count / 2]]?.title = "Renamed chip"
        _ = SidebarRegionView.layout(of: content, width: 260)
        let changed = Self.counts()
        print("label-measures n=\(count) again=\(again.measures) oneChanged=\(changed.measures)")
        #expect(again.measures == 0, "the same labels measured again: \(again.measures) of \(count)")
        #expect(changed.measures == 1, "one changed label measured \(changed.measures) of \(count)")
    }
}
