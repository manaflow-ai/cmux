import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// Wide Markdown tables scroll sideways in the app (MARKDOWN-TABLE-SCROLL, user 2026-10-20: "Right
/// now I don't think any tables are scrolling for me"). On a columns screen whose strip overflows,
/// the layout's scroll monitor took every horizontal gesture for the strip before the pane's web
/// view saw it, so a table's own scroller never moved, however the page's CSS was set up. A pane
/// view that claims the point (``HorizontalScrollClaiming``) now keeps the gesture; elsewhere the
/// strip still scrolls. This is the `layout.scrollModifier` `none` rule; with `command` (the
/// default) every plain scroll over a pane is the pane's (LayoutScrollModifierTests).
@MainActor
struct PaneHorizontalScrollClaimTests {
    /// Claims horizontal scroll over its left half only (a table there, plain text to the right).
    final class TableView: NSView, HorizontalScrollClaiming {
        var claims = true
        func claimsHorizontalScroll(at point: NSPoint) -> Bool {
            claims && point.x < bounds.midX
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var views: [PaneID: NSView] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let view: NSView = pane == "p1" ? TableView() : NSView()
            // The page's own subviews are what a hit test returns: the claim is found by walking up.
            let inner = NSView()
            inner.autoresizingMask = [.width, .height]
            view.addSubview(inner)
            views[pane] = view
            return view
        }
    }

    final class Window {
        let provider = Panes()
        // Three 60% columns on a 1000 pt window: the strip overflows, so it takes horizontal scrolls.
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "c3", width: 0.6, root: .leaf("p3")),
        ]))], activeScreenID: "s", focusedPane: "p1")
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            model.scrollModifierOverride = .noModifier
            var signals = ScrollFocusSignals()
            signals.secondsSinceKeyDown = { 60 }
            signals.windowIsKey = { _ in true }
            root = LayoutRootView(model: model, contentProvider: provider, scrollFocusSignals: signals)
            // The strip's swipe ends on its spring, not a snap: under Reduce Motion (process-wide, set
            // by suites that run alongside) it lands at once and moves p1 out from under the pointer.
            root.context.reduceMotionOverride = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            for view in provider.views.values { for inner in view.subviews { inner.frame = view.bounds } }
        }

        var table: TableView? { provider.views["p1"] as? TableView }

        /// A point in p1 (window coordinates), at `fraction` of its width.
        func point(inP1 fraction: CGFloat) throws -> CGPoint {
            let frame = try #require(root.frame(of: "p1"))
            return root.convert(CGPoint(x: frame.minX + frame.width * fraction, y: frame.midY), to: nil)
        }

        @discardableResult
        func scroll(at point: CGPoint, dx: Int32, dy: Int32 = 0, phase: CGScrollPhase? = nil,
                    units: CGScrollEventUnit = .pixel) -> Bool {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            return root.handleScroll(NSEvent(cgEvent: cg)!, locationInWindow: point)
        }

        /// A sideways trackpad swipe: began, three changes, ended. Returns how many events the layout took.
        func swipe(at point: CGPoint) -> Int {
            var taken = 0
            if scroll(at: point, dx: -20, phase: .began) { taken += 1 }
            for _ in 0..<3 where scroll(at: point, dx: -20, phase: .changed) { taken += 1 }
            if scroll(at: point, dx: 0, phase: .ended) { taken += 1 }
            return taken
        }
    }

    @Test func aSidewaysSwipeOverATableStaysWithThePane() throws {
        let w = Window()
        let before = try #require(w.root.frame(of: "p1"))
        #expect(w.swipe(at: try w.point(inP1: 0.25)) == 0, "the page under the pointer gets every event of the swipe")
        #expect(w.root.frame(of: "p1") == before, "the strip did not move")
    }

    @Test func aShiftWheelOverATableStaysWithThePane() throws {
        let w = Window()
        // A mouse's Shift+wheel arrives as a discrete horizontal notch.
        #expect(w.scroll(at: try w.point(inP1: 0.25), dx: -1, units: .line) == false)
    }

    @Test func aSidewaysSwipeOutsideTheTableStillScrollsTheStrip() throws {
        let w = Window()
        #expect(w.swipe(at: try w.point(inP1: 0.75)) > 0, "over plain text the strip takes the swipe")
    }

    @Test func aPaneThatClaimsNothingLeavesTheStripItsSwipe() throws {
        let w = Window()
        try #require(w.table).claims = false
        #expect(w.swipe(at: try w.point(inP1: 0.25)) > 0)
        #expect(w.scroll(at: try w.point(inP1: 0.25), dx: -1, units: .line) == true)
    }

    @Test func aVerticalSwipeOverATablePassesThroughAsBefore() throws {
        let w = Window()
        let point = try w.point(inP1: 0.25)
        #expect(w.scroll(at: point, dx: 0, dy: -20, phase: .began) == false)
        #expect(w.scroll(at: point, dx: 0, dy: -20, phase: .changed) == false)
        #expect(w.scroll(at: point, dx: 0, dy: 0, phase: .ended) == false)
    }
}
