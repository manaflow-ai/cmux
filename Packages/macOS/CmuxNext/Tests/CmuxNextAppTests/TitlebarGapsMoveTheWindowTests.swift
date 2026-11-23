import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/48653: the spaces between the top row's icons and tabs
/// (the sidebar toggle, Back, Forward, the sidebar's +, the tabs, the tab bar's +) did not move the
/// window. Every point of the window's titlebar band that is not a control moves the window, and a
/// double-click there runs the titlebar action (`TitlebarDragPolicy`, one decision for both); a
/// control keeps its press.
@MainActor @Suite(.serialized, .closesItsWindows) struct TitlebarGapsMoveTheWindowTests {
    struct Row {
        let window: ShellWindow
        let root: WindowRootView
        let pane: PaneContentView
    }

    func makeRow() -> Row {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        let model = TabStripModel(tabs: [TabItem(id: TabID("new"), title: "New Tab"), TabItem(id: TabID("settings"), title: "Settings")])
        let pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
        let content = WorkspaceContentView(layoutView: pane, bar: TabStripView(model: TabStripModel()))
        root.show(content)
        for _ in 0..<4 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
            pane.stripView.syncFromModel()
            pane.stripView.layoutSubtreeIfNeeded()
        }
        return Row(window: window, root: root, pane: pane)
    }

    /// What takes a press at `point` (window coordinates) as a control, judged from the views and the
    /// strip's drawn pills, not from the titlebar decision under test; nil for no control.
    func control(at point: CGPoint, in row: Row) -> String? {
        guard let frameView = row.window.contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(point, from: nil)) else { return nil }
        for view in sequence(first: hit, next: \.superview) {
            if view is NSControl { return String(describing: type(of: view)) }
            if view is SidebarResizeHandle { return "SidebarResizeHandle" }
            if view === row.window.contentView { break }
        }
        let strip = row.pane.stripView
        guard hit === strip || hit.isDescendant(of: strip) else { return nil }
        let local = strip.convert(point, from: nil)
        if strip.isInNewTabButton(local) || strip.isInNewTabMenuButton(local) { return "new tab button" }
        if strip.chipGroup(at: local) != nil { return "group chip" }
        let inClip = strip.convert(local, to: strip.tabsClip)
        for (id, cell) in strip.cells where cell.frame.width > 0.5 {
            if strip.isInCloseButton(id, local) || strip.isInAudioButton(id, local) { return "tab button" }
            let pill = strip.metrics.pillFrame(slotWidth: cell.frame.width, height: cell.frame.height)
            if inClip.x >= cell.frame.minX, inClip.x < cell.frame.minX + pill.width { return "tab pill" }
        }
        return nil
    }

    @Test func everyPointOfTheBandOffTheControlsMovesTheWindow() throws {
        let row = makeRow()
        defer { row.window.close() }
        let band = TitlebarDragPolicy.bandRect(in: row.window)
        try #require(band.height > 0, "the window has a titlebar band")
        let strip = row.pane.stripView
        try #require(WindowTitlebar.isInTopRow(strip), "the pane's tab strip is in the top row")
        try #require(strip.cells.count == 2, "both tabs are laid out")
        let frameView = try #require(row.window.contentView?.superview)

        var wrong: [String] = []
        var controls = Set<String>()
        var moving = 0
        for y in stride(from: band.maxY - 2, through: band.minY + 2, by: -4) {
            var run: (start: CGFloat, end: CGFloat, hit: String)?
            func flush() {
                guard let current = run else { return }
                wrong.append("y \(Int(band.maxY - y)) x \(Int(current.start))...\(Int(current.end)) on \(current.hit)")
                run = nil
            }
            for x in stride(from: band.minX, through: band.maxX - 1, by: 1) {
                let point = CGPoint(x: x, y: y)
                let decision = TitlebarDragPolicy.decide(at: point, in: row.window)
                if let name = control(at: point, in: row) {
                    controls.insert(name)
                    #expect(decision == .staysPut, "a press on \(name) at \(point) moves the window")
                    flush()
                    continue
                }
                guard decision != .movesWindow else { moving += 1; flush(); continue }
                let hit = frameView.hitTest(frameView.convert(point, from: nil)).map { String(describing: type(of: $0)) } ?? "nil"
                if let current = run, current.hit == hit, current.end == x - 1 { run = (current.start, x, hit) } else { flush(); run = (x, x, hit) }
            }
            flush()
        }
        #expect(moving > 0)
        // The row really has the controls whose gaps are under test.
        #expect(controls.isSuperset(of: ["TitlebarBandButton", "tab pill", "new tab button"]), "controls found: \(controls)")
        #expect(wrong.isEmpty, "points off every control that keep the window put:\n\(wrong.joined(separator: "\n"))")
    }

    /// The toolbar band's buttons stand apart: a press between two of them is no button's.
    @Test func theToolbarBandsButtonsLeaveAGapBetweenThem() throws {
        let row = makeRow()
        defer { row.window.close() }
        let band = row.root.toolbarBand
        let frames = [band.sidebarToggle, band.backButton, band.forwardButton].map { band.convert($0.frame, to: nil) }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(right.minX - left.maxX > 0.5, "\(left) and \(right) leave no gap")
            let gap = CGPoint(x: (left.maxX + right.minX) / 2, y: left.midY)
            #expect(TitlebarDragPolicy.decide(at: gap, in: row.window) == .movesWindow, "the gap at \(gap) keeps the window put")
        }
    }

    /// The gap between two tab pills and between the last pill and + is titlebar: a press there
    /// selects no tab and moves the window.
    @Test func theGapsBetweenTabPillsMoveTheWindow() throws {
        let row = makeRow()
        defer { row.window.close() }
        let strip = row.pane.stripView
        let first = try #require(strip.cells[TabID("new")])
        let inset = strip.metrics.tabBackgroundInset
        try #require(inset > 0, "the density spaces its pills")
        let gapInClip = CGPoint(x: first.frame.maxX - inset, y: strip.tabsClip.bounds.midY)
        let gap = strip.tabsClip.convert(gapInClip, to: nil)
        #expect(strip.titlebarHit(at: strip.convert(gap, from: nil)) == .empty)
        #expect(TitlebarDragPolicy.decide(at: gap, in: row.window) == .movesWindow)
        let pill = strip.tabsClip.convert(CGPoint(x: first.frame.midX - inset, y: gapInClip.y), to: nil)
        #expect(TitlebarDragPolicy.decide(at: pill, in: row.window) == .staysPut, "a tab keeps its press")
    }

    /// A strip that is not the titlebar (a lower pane's, or one that never drags the window) keeps each tab's whole
    /// slot: a press in the gap after a pill selects or drags that tab as before and never arms a pane swap
    /// (`PaneSwapDrag` starts only on `.empty`).
    @Test func aStripOutsideTheTitlebarKeepsTheWholeSlot() throws {
        let row = makeRow()
        defer { row.window.close() }
        let strip = row.pane.stripView
        strip.dragsWindowFromEmptySpace = false
        let first = try #require(strip.cells[TabID("new")])
        let inset = strip.metrics.tabBackgroundInset
        try #require(inset > 0, "the density spaces its pills")
        let gap = strip.convert(CGPoint(x: first.frame.maxX - inset, y: strip.tabsClip.bounds.midY), from: strip.tabsClip)
        #expect(strip.titlebarHit(at: gap) == .strip)
        #expect(strip.titlebarPress(atWindowPoint: strip.convert(gap, to: nil)) == .staysPut)
    }
}
