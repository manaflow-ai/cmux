import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// The live layout with a sticky column (sticky-column.md, V1 to V4, B5):
/// fixed frames above the strip, docked clipping, the overlay backdrop,
/// pointer and drop routing, the inner-edge resize and the scrollbar.
/// 1000 x 600 window, pinned style (gap 6, no padding).
@MainActor
struct StickyColumnViewTests {
    private func screens(_ sticky: StickyColumn) -> [LayoutScreen] {
        let columns = [("a", 0.5), ("b", 0.5), ("c", 0.5), ("d", 0.3)].map { id, width in
            LayoutColumn(id: ColumnID("c\(id)"), width: width, root: .leaf(PaneID(id)), sticky: id == "d" ? sticky : nil)
        }
        return [LayoutScreen(id: "s", name: "", layout: .columns(columns))]
    }

    private func makeRoot(_ sticky: StickyColumn, scrollbar: StripScrollbarMode = .auto,
                          scrollbarClock: any Clock<Duration> = ManualClock()) -> (LayoutRootView, NSWindow) {
        let model = LayoutModel(screens: screens(sticky), activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        model.stripScrollbarOverride = scrollbar
        let view = LayoutRootView(model: model, contentProvider: StickyStubProvider.shared, scrollbarClock: scrollbarClock)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func runToRest(_ view: LayoutRootView) {
        for _ in 0..<600 where view.driver.onFrame?(1.0 / 60) == true {}
    }

    private func host(_ view: LayoutRootView, _ pane: PaneID) -> PaneHostView? { view.context.hosts[pane] }

    @Test func aDockedColumnStaysPutAboveAClippedStrip() async {
        let (view, window) = makeRoot(StickyColumn(edge: .right, mode: .docked))
        defer { window.close() }
        let screen = view.screenViews["s"]!
        let sticky = CGRect(x: 702, y: 0, width: 292, height: 600)
        #expect(host(view, "d")?.frame == sticky)
        // c starts at strip x 702: under the docked column, clipped away.
        #expect(!view.model.visiblePanes.contains("c"))
        #expect(host(view, "c")?.layer?.mask?.frame.width == 0)
        let order = screen.subviews
        let stickyIndex = order.firstIndex { $0 === host(view, "d") } ?? -1
        for pane: PaneID in ["a", "b", "c"] {
            #expect((order.firstIndex { $0 === host(view, pane) } ?? .max) < stickyIndex)
        }
        view.model.focus("c")
        await settle { screen.scroll.target > 0 }
        runToRest(view)
        #expect(screen.scroll.value == screen.geometry.maxOffset)
        #expect(host(view, "d")?.frame == sticky)
        #expect(abs((host(view, "c")?.frame.maxX ?? 0) - 696) < 0.5)
        #expect(view.model.visiblePanes.isSuperset(of: ["c", "d"]))
    }

    @Test func anOverlayColumnFloatsOnAGlassBackdrop() {
        let (view, window) = makeRoot(StickyColumn(edge: .right, mode: .overlay))
        defer { window.close() }
        let screen = view.screenViews["s"]!
        #expect(screen.backdrops.count == 1)
        #expect(screen.backdrops["cd"]?.frame == CGRect(x: 699, y: 0, width: 298, height: 600))
        let order = screen.subviews
        let backdrop = order.firstIndex { $0 === screen.backdrops["cd"] } ?? -1
        #expect((order.firstIndex { $0 === host(view, "b") } ?? .max) < backdrop)
        #expect(backdrop < (order.firstIndex { $0 === host(view, "d") } ?? -1))
        // b reaches under the overlay; the pointer there belongs to d.
        #expect(screen.pane(at: CGPoint(x: 900, y: 300)) == "d")
        #expect(screen.pane(at: CGPoint(x: 600, y: 300)) == "b")
        #expect(view.model.visiblePanes == ["a", "b", "d"])
        // Clicks in the cover never reach the strip pane under it.
        let edge = screen.hitTest(screen.convert(CGPoint(x: 998, y: 300), to: view))
        #expect(!(edge is PaneHostView) || (edge as? PaneHostView)?.pane == "d")
        let rim = screen.hitTest(screen.convert(CGPoint(x: 700, y: 300), to: view))
        #expect(rim === screen)
    }

    @Test func directionalFocusReachesColumnsPastARightStickyColumn() {
        let (view, window) = makeRoot(StickyColumn(edge: .right, mode: .docked))
        defer { window.close() }
        let frames = view.navigationFrames
        // d sits after the strip's end, so right from b reaches c first.
        #expect(FocusNavigation.neighbor(of: "b", direction: .right, frames: frames) == "c")
        #expect(FocusNavigation.neighbor(of: "c", direction: .right, frames: frames) == "d")
    }

    @Test func aTabDragOverTheStickyColumnTargetsItsPane() {
        let (view, window) = makeRoot(StickyColumn(edge: .right, mode: .overlay))
        defer { window.close() }
        #expect(view.updateTabDrag("t", locationInWindow: NSPoint(x: 848, y: 300)) == .pane("d", .center))
        #expect(view.updateTabDrag("t", locationInWindow: NSPoint(x: 700, y: 300)) == nil)
        #expect(view.updateTabDrag("t", locationInWindow: NSPoint(x: 300, y: 300)) == .pane("a", .center))
        view.cancelTabDrag()
    }

    @Test func dragginTheInnerEdgeOfARightColumnWidensIt() {
        let (view, window) = makeRoot(StickyColumn(edge: .right, mode: .docked))
        defer { window.close() }
        var widths: [Double] = []
        view.model.intentHandler = { intent in
            if case let .setColumnWidth(column, _, width, _, .ended) = intent, column == "cd" { widths.append(width) }
        }
        let screen = view.screenViews["s"]!
        screen.handleDrag(kind: .columnEdge("cd"), event: .began(NSPoint(x: 704, y: 300)))
        screen.handleDrag(kind: .columnEdge("cd"), event: .moved(NSPoint(x: 604, y: 300)))
        screen.handleDrag(kind: .columnEdge("cd"), event: .ended(NSPoint(x: 604, y: 300)))
        // 392 pt of a 1000 pt view: (392 + 6) / 994.
        #expect(widths.count == 1)
        #expect(abs((widths.first ?? 0) - 398.0 / 994.0) < 0.002)
    }

    @Test func theScrollbarShowsOnScrollAndHidesWhenOff() async {
        let clock = ManualClock()
        let (view, window) = makeRoot(StickyColumn(edge: .right, mode: .docked), scrollbar: .auto, scrollbarClock: clock)
        defer { window.close() }
        let screen = view.screenViews["s"]!
        #expect(screen.scrollbar?.isShown == false)
        // A loaded CI runner can take longer than the 1.2 s fade-out to rest.
        screen.scrollbar?.idleDelay = .seconds(3600)
        view.model.focus("c")
        await settle { screen.scroll.target > 0 }
        runToRest(view)
        // Reproduces #16607: the idle delay elapses before the check, as it
        // did when a loaded runner stalled the settle loop past 1.2 s.
        await settle {
            clock.advance(by: StripScrollbarView.idleDelay)
            return screen.scrollbar?.isShown == false
        }
        #expect(screen.scrollbar?.isShown == true)
        let report = screen.scrollbarReport
        // The track spans the strip's uncovered range only.
        #expect((report?.band.maxX ?? .infinity) <= 702)
        #expect(report?.thumb != nil)
        view.model.stripScrollbarOverride = .off
        await settle { screen.scrollbar?.isHidden == true }
        #expect(screen.scrollbar?.isHidden == true)
    }

    @Test func noScrollbarWhenTheColumnsFit() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns([
            LayoutColumn(id: "ca", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "cd", width: 0.3, root: .leaf("d"), sticky: StickyColumn()),
        ]))], activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        model.stripScrollbarOverride = .always
        let view = LayoutRootView(model: model, contentProvider: StickyStubProvider.shared)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(view.screenViews["s"]?.scrollbar?.isShown != true)
    }
}

@MainActor
private final class StickyStubProvider: LayoutPaneContentProvider {
    static let shared = StickyStubProvider()
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}
