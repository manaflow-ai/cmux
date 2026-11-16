import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Which row views a space switch shows the rows of the space in. The list gave the rows that come the views of the
/// space that leaves (the pool's rebinding), so a window with two spaces had the views of one page: each switch set
/// every row's title, icon and marks again in a view that showed another row, and drew them again, in the turn of the
/// key. A space keeps its row views while another shows, as Chromium keeps each tab's contents view and swaps the
/// shown one in (`BrowserView::OnActiveTabChanged`), and the views a space needs the first time are made before the
/// switch, after frames committed, as Chromium keeps a spare renderer (`SpareRenderProcessHostManager`).
/// 24 workspaces, half in each of two spaces: 12 rows a space, fewer than the smallest page of spares (16).
@MainActor @Suite(.serialized)
struct SpaceSwitchRowViewsTests {
    /// Waits until two main run-loop passes have committed, so work after a frame's commit has run (the signal
    /// `AfterFrameCommit` uses: a one-shot before-waiting observer after every other observer of the pass).
    private static func nextTurns() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                  false, CFIndex.max) { _, _ in
                    done.resume()
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            }
        }
    }

    /// The window at rest: the list makes the spare row views it wants (one per committed pass) until it wants no more.
    private static func idle(_ bench: SpaceSwitchBench) async {
        // A test window may sit off any screen or covered on a fleet runner: it counts as shown here.
        bench.list.windowShowsRows = { _ in true }
        var last = -1
        for _ in 0..<120 {
            bench.list.scheduleSpareRow()
            await nextTurns()
            let count = bench.list.rowPool.spares.count
            if count == last, !bench.list.spareRowScheduled { break }
            last = count
        }
    }

    /// The view of each workspace row the list shows now.
    private static func shownViews(_ bench: SpaceSwitchBench) -> [SidebarRowKey: WorkspaceRowView] {
        bench.list.rowViews.compactMapValues { $0 as? WorkspaceRowView }
    }

    /// The shown workspace rows whose view does not show the row's title.
    private static func wrongTitles(_ bench: SpaceSwitchBench) -> [String] {
        shownViews(bench).compactMap { key, view in
            guard case let .workspace(id) = key, let title = bench.list.workspaces[id]?.title else { return "\(key): no row" }
            return view.title.stringValue == title && !view.isHidden ? nil : "\(title) shows as \(view.title.stringValue)"
        }
    }

    /// The first switch to a space, from a window at rest: its rows show in views that showed no row of the space
    /// that leaves, and the switch's turn makes no row view (the page of views was made before the key).
    @Test func aSpaceShownForTheFirstTimeTakesNoViewOfTheSpaceThatLeaves() async throws {
        let bench = try await SpaceSwitchBench(total: 24, registered: true)
        defer { bench.close() }
        await Self.idle(bench)
        let spares = bench.list.rowPool.spares.count
        let left = Set(Self.shownViews(bench).values.map(ObjectIdentifier.init))
        try #require(left.count >= 8, "the first space shows \(left.count) workspace rows")
        let counters = try await bench.settledSwitch(to: bench.rooms[1])
        let shown = Self.shownViews(bench)
        let taken = shown.values.filter { left.contains(ObjectIdentifier($0)) }.count
        let made = counters["row_views_made"] ?? 0
        print("SPACE-SWITCH-ROW-VIEWS first rows=\(shown.count) spares_before=\(spares) taken_from_the_space_that_left=\(taken) row_views_made=\(made)")
        #expect(shown.count >= 8, "the second space shows \(shown.count) workspace rows")
        #expect(taken == 0, "\(taken) of \(shown.count) rows of the space show in views of the space that left: that space has none when it shows again")
        #expect(made == 0, "the switch's turn made \(made) row views")
        #expect(Self.wrongTitles(bench).isEmpty, "rows show another title: \(Self.wrongTitles(bench))")
    }

    /// Switches back and forth with no rest between them: each row of a space shows in the view it had when the
    /// person left the space, with its title, and no switch makes a row view.
    @Test func aSpaceShownAgainShowsEachRowInTheViewItHad() async throws {
        let bench = try await SpaceSwitchBench(total: 24, registered: true)
        defer { bench.close() }
        await Self.idle(bench)
        var had: [Int: [SidebarRowKey: ObjectIdentifier]] = [:]
        had[0] = Self.shownViews(bench).mapValues(ObjectIdentifier.init)
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        var current = 1
        for round in 0..<6 {
            had[current] = Self.shownViews(bench).mapValues(ObjectIdentifier.init)
            let target = 1 - current
            let counters = try await bench.settledSwitch(to: bench.rooms[target])
            current = target
            let now = Self.shownViews(bench).mapValues(ObjectIdentifier.init)
            let before = had[target] ?? [:]
            let other = now.filter { before[$0.key] != $0.value }.count
            let made = counters["row_views_made"] ?? 0
            print("SPACE-SWITCH-ROW-VIEWS again round=\(round) rows=\(now.count) rows_in_another_view=\(other) row_views_made=\(made) "
                + "row_configures=\(counters["row_configures"] ?? 0)")
            #expect(now.count == before.count && now.count >= 8, "round \(round): the space shows \(now.count) workspace rows, it had \(before.count)")
            #expect(other == 0, "round \(round): \(other) of \(now.count) rows show in a view that another row had")
            #expect(made == 0, "round \(round): the switch's turn made \(made) row views")
            #expect(Self.wrongTitles(bench).isEmpty, "round \(round): rows show another title: \(Self.wrongTitles(bench))")
        }
    }

    /// A workspace row with no status line: its status block has nothing to place, so a configure with no line and
    /// the block's draw ask for no layout (each one was a layout of the block, with a read of the layout metrics,
    /// for every row of a switch).
    @Test func aStatusBlockWithNoLineAsksForNoLayout() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let block = WorkspaceStatusView()
        block.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        window.contentView?.addSubview(block)
        block.configure(SidebarWorkspaceStatus(), reservesBar: false)
        window.contentView?.layoutSubtreeIfNeeded()
        try #require(!block.needsLayout, "the block did not lay out")
        block.configure(SidebarWorkspaceStatus(), reservesBar: false)
        #expect(!block.needsLayout, "a configure with no line, after no line, asks for a layout of the block")
        window.contentView?.layoutSubtreeIfNeeded()
        block.updateLayer()
        #expect(!block.needsLayout, "the draw of a block with no line asks for a second layout, in the commit of the frame")
    }

    /// A plain status line (no pill) is as wide as its block (`WorkspaceStatusView.layout`). The draw no longer asks
    /// for a layout each time, so a new width of the block (a sidebar resize sets the block's frame, with no
    /// configure) must place the line again on its own.
    @Test func aPlainStatusLineFollowsItsBlocksWidthWithNoConfigure() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let block = WorkspaceStatusView()
        block.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        window.contentView?.addSubview(block)
        block.configure(SidebarWorkspaceStatus(entries: [.init(key: "build", text: "Building")]), reservesBar: false)
        window.contentView?.layoutSubtreeIfNeeded()
        block.updateLayer()
        window.contentView?.layoutSubtreeIfNeeded()
        let line = try #require(block.subviews.compactMap { $0 as? NSTextField }.first, "the block has no line")
        try #require(line.frame.width == 200, "the line is \(line.frame.width) pt wide in a block of 200 pt")
        try #require(!block.needsLayout, "the block did not lay out")
        block.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
        window.contentView?.layoutSubtreeIfNeeded()
        print("SPACE-SWITCH-ROW-VIEWS status_line_width=\(line.frame.width) block_width=\(block.bounds.width)")
        #expect(line.frame.width == 120, "the line stays \(line.frame.width) pt wide in a block of 120 pt")
    }
}
