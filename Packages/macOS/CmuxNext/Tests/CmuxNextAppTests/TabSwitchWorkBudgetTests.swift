import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import QuartzCore
import Testing

// The strip's tab ids, not the layout's (CmuxNextLayout has its own `TabID`).
private typealias TabID = CmuxNextTabs.TabID

/// tab-switch-rewrite (u2873): the strip's work budget for a tab switch, deterministic where timing on
/// shared CI hosts is not. Switching between tabs that already show, at rest, walks no row of tabs (no
/// occlusion pass, no full separator pass, no frame pass) at 2, 10 or 30 tabs: its cost is the two
/// cells whose selection changed. A change that brings back an O(tabs) pass on the switch path fails here.
///
/// The same budget for what else happens to a strip while a person uses it (tab strip jank audit,
/// 2026-10-27): a wheel scroll moves the scrolling layer's bounds and places no tab; a title or spinner
/// changes that tab's cell and lays nothing out; a pane springing to a new width lays its strip out once,
/// at its rest width; a drag step re-cuts no mask of the whole row; the pointer moving over the strip asks
/// the window server nothing. Each test prints its counts (`work-budget`), the before/after record.
@MainActor @Suite(.serialized)
struct TabSwitchWorkBudgetTests {
    @Test(arguments: [2, 10, 30])
    func aSwitchAtRestWalksNoRow(_ count: Int) {
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 1800, height: 40) // 30 tabs at their narrowest width fit with the pane insets
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        strip.syncFromModel()
        CATransaction.flush()
        #expect(!strip.result.isOverflowing, "every tab shows: no switch scrolls")
        let before = strip.rowPasses
        for item in items.reversed() + items {
            model.selectedID = item.id
            strip.syncFromModel()
            #expect(strip.cells[item.id]?.isSelected == true)
        }
        #expect(strip.rowPasses == before, "\(2 * count) switches walked the row: \(before) -> \(strip.rowPasses)")
    }

    // MARK: Beyond the switch

    /// A crowded strip of `count` tabs in a `width` pt window, shown and settled.
    private struct Crowded {
        let window: NSWindow
        let strip: TabStripView
        let model: TabStripModel

        init(count: Int = 40, width: CGFloat = 700, selected: Int? = nil) {
            DesignSettings.shared.tabOverflow = .shrink
            let tabs = (0..<count).map { TabItem(id: TabID("w\($0)"), title: "Tab \($0)") }
            model = TabStripModel(tabs: tabs, selectedID: tabs[selected ?? count - 1].id)
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }

        /// How many tab layers' frames differ from `frames`.
        func moved(since frames: [TabID: CGRect]) -> Int { strip.cells.count(where: { frames[$0.key] != $0.value.layer.frame }) }
        var frames: [TabID: CGRect] { strip.cells.mapValues(\.layer.frame) }
    }

    private static func report(_ name: String, _ counts: KeyValuePairs<String, Int>) {
        print("work-budget \(name): " + counts.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }

    /// Wheel steps over a crowded strip: the scroll moves, and no tab layer is placed again.
    @Test func aWheelScrollPlacesNoTab() throws {
        let crowded = Crowded()
        defer { crowded.window.close() }
        let strip = crowded.strip
        try #require(strip.result.isOverflowing && strip.scrollOffset > 0)
        let before = strip.rowPasses, start = strip.scrollOffset
        var moved = 0
        for _ in 0..<20 {
            let frames = crowded.frames
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 8, wheel3: 0))
            strip.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
            moved += crowded.moved(since: frames)
        }
        #expect(strip.scrollOffset < start, "the wheel did not scroll: \(start) -> \(strip.scrollOffset)")
        let passes = strip.rowPasses
        Self.report("wheel x20, \(strip.cells.count) tabs", ["framePasses": passes.frames - before.frames, "tabLayersMoved": moved,
                                                            "occlusionPasses": passes.occlusion - before.occlusion])
        #expect(moved == 0, "20 wheel steps moved \(moved) tab layers")
        #expect(passes.frames == before.frames && passes.occlusion == before.occlusion, "\(before) -> \(passes)")
        // What shows still follows the scroll: the selected tab's frame in the strip's clip moved with it.
        let cell = try #require(strip.cells[TabID("w39")])
        let slot = try #require(strip.result.slot(cell.item.id))
        #expect(abs(cell.frame.minX - (slot.x - strip.scrollOffset)) <= 0.5)
    }

    /// Titles and spinners changing on tabs that stay where they are: each changed cell redraws; no row pass.
    @Test func aTitleOrSpinnerChangeLaysNothingOut() {
        let crowded = Crowded(count: 30, width: 1800)
        defer { crowded.window.close() }
        let strip = crowded.strip, model = crowded.model
        let before = strip.rowPasses
        for step in 0..<20 {
            var tabs = model.tabs
            tabs[step % tabs.count].title = "Build \(step)"
            tabs[(step + 7) % tabs.count].isBusy = step.isMultiple(of: 2)
            model.tabs = tabs
            strip.syncFromModel()
        }
        let passes = strip.rowPasses
        Self.report("title+spinner x20, \(strip.cells.count) tabs", ["framePasses": passes.frames - before.frames,
                                                                    "separatorPasses": passes.separators - before.separators])
        #expect(strip.cells[TabID("w19")]?.item.title == "Build 19", "the cell did not take its new title")
        #expect(passes.frames == before.frames && passes.separators == before.separators, "\(before) -> \(passes)")
    }

    /// A drag step that reorders nothing re-cuts no mask of the whole row.
    @Test func aDragStepCutsNoMaskOfTheRow() throws {
        let crowded = Crowded(count: 12, width: 1800, selected: 5)
        defer { crowded.window.close() }
        let strip = crowded.strip
        let id = TabID("w5")
        let cell = try #require(strip.cells[id])
        let start = strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        strip.beginDrag(TabStripPress(id: id, start: start))
        let before = strip.rowPasses
        for step in 1...20 { strip.updateDrag(at: CGPoint(x: start.x + CGFloat(step) * 0.5, y: start.y), event: nil) }
        let passes = strip.rowPasses
        strip.cancelDrag()
        Self.report("drag step x20, \(strip.cells.count) tabs", ["framePasses": passes.frames - before.frames,
                                                                "occlusionPasses": passes.occlusion - before.occlusion])
        #expect(passes.occlusion == before.occlusion, "20 drag steps re-cut the whole row's masks: \(before) -> \(passes)")
    }

    /// The pointer moving over the strip's tabs asks the window server nothing: its own event names its window.
    @Test func pointerMovesOverTheStripAskTheWindowServerNothing() throws {
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = false
        defer { WindowPlacement.noActivate = saved }
        let crowded = Crowded(count: 8, width: 1200)
        defer { crowded.window.close() }
        let strip = crowded.strip
        crowded.window.orderFrontRegardless()
        final class Count { var queries = 0 }
        let count = Count()
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.pointerLocation = { .zero }
        coordinator.windowNumberAt = { [weak window = crowded.window] _ in count.queries += 1; return window?.windowNumber }
        strip.hoverCards = coordinator
        defer { coordinator.dismiss(.action) }
        let cells = strip.model.tabs.compactMap { strip.cells[$0.id] }
        var moves = 0
        for cell in cells {
            for dx in stride(from: 4, to: cell.frame.width - 4, by: 6) {
                strip.updateHover(at: strip.convert(CGPoint(x: cell.frame.minX + dx, y: cell.frame.midY), from: strip.tabsClip), moved: true)
                moves += 1
            }
        }
        Self.report("pointer moves x\(moves)", ["windowServerQueries": count.queries])
        #expect(coordinator.machine.lastHit != nil, "the moves hit no tab")
        #expect(count.queries == 0, "\(moves) pointer moves asked the window server \(count.queries) times")
    }

    /// A pane springing from 800 to 400 pt (a split) lays its strip out once, at its rest width, not on every frame.
    @Test func aPaneSpringLaysItsStripOutOnce() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tabs = (0..<12).map { TabItem(id: TabID("s\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: LaunchReveal(deadline: .zero))
        let host = PaneHostView(pane: CmuxNextLayout.PaneID("spring"), content: pane, holdsContentInMotion: { false })
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        window.contentView = root
        root.addSubview(host)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        host.layoutSubtreeIfNeeded()
        let strip = pane.stripView
        strip.syncFromModel()
        host.layoutSubtreeIfNeeded()
        let before = strip.rowPasses
        host.restSize = CGSize(width: 400, height: 300)
        host.isOnLayoutSpring = true
        var frames = 0
        for width in stride(from: 790.0, through: 400, by: -10) {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            host.layoutSubtreeIfNeeded()
            frames += 1
        }
        let during = strip.rowPasses
        host.isOnLayoutSpring = false
        host.layoutSubtreeIfNeeded()
        Self.report("pane spring \(frames) frames", ["stripRelayouts": during.separators - before.separators,
                                                    "framePasses": during.frames - before.frames])
        #expect(during.separators - before.separators <= 1, "the strip laid out on each frame: \(before) -> \(during)")
        #expect(during.frames - before.frames <= 1, "the strip placed its tabs on each frame: \(before) -> \(during)")
        #expect(abs(strip.viewportWidth - strip.lastViewportWidth) < 0.5 && strip.bounds.width <= 400, "landed at \(strip.bounds.width)")
    }
}
