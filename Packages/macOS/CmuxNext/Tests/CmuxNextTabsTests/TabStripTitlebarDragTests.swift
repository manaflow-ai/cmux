import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// Dogfood nxdog12: "tabs at top drag full window around". A strip in the
/// titlebar band of a full-size-content window: pressing a tab or the +
/// button must never move the window; only empty strip space
/// does.
///
/// macOS decides a titlebar drag from a region AppKit precomputes before the
/// app sees the mouse-down, so the window-level check reads AppKit's own
/// region (`AppKitTitlebarDragRegion`, test-only private API). A synthesized
/// event cannot exercise that path, and `debug.mouse` cannot either.
@MainActor @Suite(.serialized) struct TabStripTitlebarDragTests {
    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView

        init(titles: [String]) {
            let tabs = titles.enumerated().map { TabItem(id: TabID("t\($0.offset)"), title: $0.element) }
            model = TabStripModel(tabs: tabs, selectedID: tabs.first?.id)
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            window.contentView = root
            // The top-left strip of a minimal-titlebar window, after the traffic
            // lights. It stops 100 pt short of the window's trailing edge: AppKit's
            // resize border there keeps the window put, which is not the strip's
            // decision (with no trailing buttons, the strip's end is empty space).
            strip.frame = NSRect(x: 100, y: 400 - TabStripView.preferredHeight, width: 700, height: TabStripView.preferredHeight)
            root.addSubview(strip)
            strip.sync(fromModel: true)
            strip.layoutSubtreeIfNeeded()
        }

        /// Window point at the vertical middle of the strip, `x` from its leading edge.
        func windowPoint(stripX x: CGFloat) -> CGPoint {
            strip.convert(CGPoint(x: x, y: strip.bounds.midY), to: nil)
        }

        func tabCenterX(_ index: Int) -> CGFloat {
            let cell = strip.cells[TabID("t\(index)")]!
            return strip.tabsClip.convert(CGPoint(x: cell.frame.midX, y: 0), to: strip).x
        }

        func close() { window.close() }
    }

    @Test func theDecisionIsPerPoint() {
        let rects = [CGRect(x: 80, y: 0, width: 300, height: 28), CGRect(x: 700, y: 0, width: 60, height: 28)]
        #expect(TabStripView.titlebarHit(at: CGPoint(x: 10, y: 14), mouseRects: rects) == .empty)
        #expect(TabStripView.titlebarHit(at: CGPoint(x: 80, y: 14), mouseRects: rects) == .strip)
        #expect(TabStripView.titlebarHit(at: CGPoint(x: 379.5, y: 14), mouseRects: rects) == .strip)
        #expect(TabStripView.titlebarHit(at: CGPoint(x: 380, y: 14), mouseRects: rects) == .empty)
        #expect(TabStripView.titlebarHit(at: CGPoint(x: 720, y: 2), mouseRects: rects) == .strip)
        #expect(TabStripView.titlebarHit(at: CGPoint(x: 760, y: 14), mouseRects: [ ]) == .empty)
    }

    /// The strip's rule and the window's decision agree every 4 pt, and
    /// follow a tab added after the first layout.
    @Test func thePolicyFollowsTheStripRuleAtEveryPoint() {
        let pin = StripHeightPin()
        defer { pin.restore() }
        let h = Harness(titles: ["One", "Two"])
        defer { h.close() }
        h.model.tabs.append(TabItem(id: TabID("t2"), title: "Three"))
        h.strip.sync(fromModel: true)
        h.strip.layoutSubtreeIfNeeded()
        h.strip.relayout(animated: false)
        for x in stride(from: CGFloat(1), to: h.strip.bounds.width, by: 4) {
            let hit = h.strip.titlebarHit(at: CGPoint(x: x, y: h.strip.bounds.midY))
            let press = TitlebarDragPolicy.decide(at: h.windowPoint(stripX: x), in: h.window)
            #expect(press == (hit == .empty ? .movesWindow : .staysPut), "x \(x): \(hit) \(press)")
        }
        #expect(TitlebarDragPolicy.decide(at: h.windowPoint(stripX: h.tabCenterX(2)), in: h.window) == .staysPut)
    }
}

/// AppKit's titlebar drag decision for a full-size-content window: the theme
/// frame's region of views that claim the mouse in the titlebar band. Test
/// only: private AppKit and SkyLight API, looked up at run time.
@MainActor
struct AppKitTitlebarDragRegion {
    private typealias RegionFunction = @convention(c) (AnyObject, Selector, CGRect, Bool, Bool) -> AnyObject?
    private typealias ContainsFunction = @convention(c) (AnyObject, UnsafePointer<CGPoint>) -> Bool
    private let region: AnyObject
    private let contains: ContainsFunction

    init?(window: NSWindow) {
        window.displayIfNeeded()
        let selector = NSSelectorFromString("_regionForOpaqueDescendants:forMove:forUnderTitlebar:")
        guard let frameView = window.contentView?.superview, frameView.responds(to: selector),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSPointInRegion") else { return nil }
        let function = unsafeBitCast(frameView.method(for: selector), to: RegionFunction.self)
        guard let region = function(frameView, selector, frameView.bounds, true, false) else { return nil }
        self.region = region
        contains = unsafeBitCast(symbol, to: ContainsFunction.self)
    }

    /// Whether a press at `point` (window coordinates) is claimed by a view,
    /// so dragging from it does not move the window.
    func blocksWindowDrag(at point: CGPoint) -> Bool {
        var point = point
        return contains(region, &point)
    }
}
