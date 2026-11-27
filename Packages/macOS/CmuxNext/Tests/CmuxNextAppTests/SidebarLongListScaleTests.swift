import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-10: "our f***ing thing is too slow to scroll through the side bar / where's our performance / where's
/// our infinite scroll"; 2026-11-04: interaction cost stays constant as workspaces grow ("never ... acceptable ...
/// linear time growth degradation"). The detector for unvirtualized long lists (cmuxterm-hq
/// docs/patterns/unvirtualized-long-lists.md): the same scroll over 50, 500 and 2,000 workspaces holds the same views
/// and does the same work per frame. A list that makes a view per item, or a scroll that visits every item, grows
/// with the count and fails here by name. Prints one `SIDEBAR-LONG-LIST` line per size, the before/after numbers.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)))
struct SidebarLongListScaleTests {
    static let sizes = [50, 500, 2_000]

    struct Sample {
        var count: Int
        /// Every view in the sidebar's tree after the scroll (rows, their subviews, blocks' items).
        var views: Int
        var rowViews: Int
        var configuresPerFrame: Double
        var cpuP50: Double
        var cpuP99: Double

        var line: String {
            String(format: "count=%d views=%d row_views=%d configures/frame=%.2f cpu_ms p50 %.3f p99 %.3f",
                   count, views, rowViews, configuresPerFrame, cpuP50, cpuP99)
        }
    }

    static func viewCount(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + viewCount($1) } }

    /// The same scroll (two screens down and back, 40 pt a frame, warm-up pass dropped) over `count` workspaces.
    static func scroll(_ count: Int, shape: SidebarScrollBench.Shape) -> Sample {
        let bench = SidebarScrollBench(count: count, shape: shape)
        defer { bench.close() }
        let frames = bench.run(passes: 1, depth: 1_800)
        let cpu = frames.map(\.cpuMs)
        return Sample(count: count, views: viewCount(bench.sidebar), rowViews: bench.rowViewsInList,
                      configuresPerFrame: Double(frames.map(\.configures).reduce(0, +)) / Double(max(frames.count, 1)),
                      cpuP50: SidebarScrollBench.percentile(cpu, 0.5), cpuP99: SidebarScrollBench.percentile(cpu, 0.99))
    }

    static func check(_ samples: [Sample], _ what: String) {
        guard let small = samples.first(where: { $0.count == 500 }), let large = samples.first(where: { $0.count == 2_000 }) else { return }
        // A screenful of rows past the 50-workspace list's end is the only difference allowed: 500 and 2,000 both
        // scroll the same two screens of a list longer than them.
        #expect(large.rowViews <= small.rowViews + 2, "\(what): row views grew with the list: \(small.line) -> \(large.line)")
        #expect(large.views <= small.views + small.views / 10,
                "\(what): the sidebar holds more views at 2,000 workspaces than at 500: \(small.line) -> \(large.line)")
        #expect(large.configuresPerFrame <= small.configuresPerFrame * 1.25 + 0.5,
                "\(what): a scroll frame configures more rows at 2,000 workspaces: \(small.line) -> \(large.line)")
        // Linear work would be 4x here; frame CPU on one host, back to back, stays well inside 2.5x when constant.
        #expect(large.cpuP50 <= max(small.cpuP50 * 2.5, small.cpuP50 + 1),
                "\(what): a scroll frame's median main-thread time grew with the list: \(small.line) -> \(large.line)")
    }

    @Test func aScrollHoldsTheSameViewsAndWorkAtFiftyFiveHundredAndTwoThousandWorkspaces() {
        for (name, shape) in [("mixed", SidebarScrollBench.Shape.mixed), ("one-group", .oneGroup)] {
            let samples = Self.sizes.map { Self.scroll($0, shape: shape) }
            for sample in samples { print("SIDEBAR-LONG-LIST list shape=\(name) " + sample.line) }
            Self.check(samples, "the workspace list (\(name))")
        }
    }

    /// A workspace that moves to the top while the list scrolls (a notification's move to the top, a structural set)
    /// laid every row out again (sidebar-scroll-perf-DESIGN.md cause 3), so its frame grew with the list. The move now
    /// takes the one row out and splices it back (`SidebarLayout.removeLoose`, `insertLoose`): the rows laid out per
    /// move stay the same at 50, 500 and 2,000 workspaces. Printed with the splice off (before)
    /// and on (after), from this one harness.
    @Test func aMoveWhileScrollingLaysOutTheSameRowsAtEverySize() {
        var after: [Int: (laidOut: Int, moves: Int)] = [:]
        for splices in [false, true] {
            for count in Self.sizes {
                let bench = SidebarScrollBench(count: count)
                defer { bench.close() }
                bench.model.splicesRemovals = splices
                bench.moveToTopEvery = 10
                let frames = bench.run(passes: 1, depth: 1_800)
                let moves = frames.filter { $0.reloads > 0 }
                let cpu = moves.map(\.cpuMs)
                let laidOut = moves.map(\.laidOut).reduce(0, +)
                let p50 = SidebarScrollBench.percentile(cpu, 0.5)
                print(String(format: "SIDEBAR-LONG-LIST move-to-top %@ count=%d moves=%d rows_laid_out_per_move=%.1f move_frame_cpu_ms p50 %.3f p99 %.3f max %.3f",
                             splices ? "after" : "before", count, moves.count, Double(laidOut) / Double(max(moves.count, 1)), p50,
                             SidebarScrollBench.percentile(cpu, 0.99), cpu.max() ?? 0))
                if splices { after[count] = (laidOut, moves.count) }
            }
        }
        for count in Self.sizes {
            guard let a = after[count] else { continue }
            #expect(a.moves > 0, "no move frame at \(count) workspaces")
            // One row out and one back in: two per move, never a full layout.
            #expect(a.laidOut <= 2 * a.moves, "a move laid out \(a.laidOut) rows over \(a.moves) moves at \(count) workspaces")
        }
        // The frame times are printed, not checked: the rows laid out are the host-independent measure.
    }

    /// A Pinned (or custom) section draws its items in one block row (`SidebarBlockRowView`): the block is one list
    /// row, so the list's realization never reached inside it, and its region made a view for every item.
    @Test func aLongPinnedBlockMakesViewsOnlyForTheItemsNearTheScreen() throws {
        var held: [Int: Int] = [:]
        for count in Self.sizes {
            let fixture = try PinnedBlockFixture(items: count)
            defer { fixture.close() }
            fixture.scroll(to: 1_200)
            let region = try #require(fixture.region, "no block row realized at \(count) pinned items")
            let shown = region.itemViews.values.filter { fixture.visibleInList($0) }.count
            held[count] = region.itemViews.count
            print("SIDEBAR-LONG-LIST pinned count=\(count) item_views=\(region.itemViews.count) visible=\(shown) views=\(Self.viewCount(fixture.scrollView))")
            #expect(shown > 0, "no pinned item shows after the scroll at \(count) items")
            // The screen, the overscan above and below it, and at most the prune margin kept past that.
            let margin = Int((2 * (SidebarStyle.overscan + SidebarStyle.pruneMargin) / SidebarRegionMetrics.standard.rowHeight).rounded(.up)) + 2
            #expect(region.itemViews.count <= shown + margin,
                    "the Pinned block holds \(region.itemViews.count) item views for \(shown) on screen at \(count) items")
        }
        if let small = held[500], let large = held[2_000] {
            #expect(large <= small + 2, "the Pinned block's item views grew with its items: \(small) at 500, \(large) at 2,000")
        }
    }

    /// Scrolling through the block realizes the items that come in and drops the ones that leave.
    @Test func scrollingThroughALongPinnedBlockShowsEveryItemItReaches() throws {
        let fixture = try PinnedBlockFixture(items: 500)
        defer { fixture.close() }
        for y in stride(from: CGFloat(0), through: 8_000, by: 400) {
            fixture.scroll(to: y)
            let region = try #require(fixture.region)
            let clip = fixture.scrollView.contentView.bounds
            // Every item row whose frame the clip shows has a view.
            let block = try #require(fixture.blockRowY)
            let missing = region.layoutResult.rows.compactMap { row -> LayoutItemID? in
                guard case let .item(id, _) = row.kind else { return nil }
                let inList = row.frame.offsetBy(dx: 0, dy: block)
                return inList.intersects(clip) && region.itemView(id) == nil ? id : nil
            }
            #expect(missing.isEmpty, "at y=\(y) items on screen have no view: \(missing.prefix(3).map(\.rawValue))")
        }
    }
}

/// A list in a scroll view whose Pinned block holds `items` pinned workspaces, over a few loose workspace rows.
@MainActor final class PinnedBlockFixture {
    let list: SidebarListView
    let scrollView = NSScrollView()
    let window: NSWindow

    init(items count: Int, height: CGFloat = 900) throws {
        _ = NSApplication.shared
        let items = (0..<count).map { LayoutItem(id: LayoutItemID("itm_pin_\($0)"), ref: .workspace("local:ws-pin-\($0)")) }
        var infos: [LayoutItemID: SidebarItemInfo] = [:]
        for (index, item) in items.enumerated() {
            var info = SidebarItemInfo(title: "Pinned workspace \(index)", symbol: "textformat")
            info.textOnly = true
            info.workspace = WorkspaceID("ws-pin-\(index)")
            infos[item.id] = info
        }
        let pinned = SidebarLayoutDocument.pinnedSection(items: items)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: (0..<5).map { .workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "ws \($0)")) }),
        ])
        list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [pinned.id.rawValue: pinned], infos: infos, collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 260, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        scrollView.hasVerticalScroller = false
        scrollView.documentView = list
        window.contentView = scrollView
        list.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.fitToClip()
        list.layoutSubtreeIfNeeded()
    }

    func close() { window.close() }

    var region: SidebarRegionView? { list.blockRegions.first }

    /// The block row's y in the list.
    var blockRowY: CGFloat? {
        list.displayed.rows.first { if case .block = $0.key { true } else { false } }?.y
    }

    func scroll(to y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: min(y, max(0, list.frame.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
        list.realizeVisibleRows()
        list.layoutSubtreeIfNeeded()
    }

    func visibleInList(_ view: NSView) -> Bool {
        list.convert(view.bounds, from: view).intersects(scrollView.contentView.bounds)
    }
}
