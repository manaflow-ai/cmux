import AppKit
@testable import CmuxNextLayout
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Page scrolls leave the layout's scroll routing in O(1): a plain scroll from a
/// Chromium page's window, and the changes and coast of any gesture the layout did not take, go on
/// with no point conversion, pane hit test or claim query (`LayoutRootView+ScrollPassThrough`,
/// counted by `routedScrolls`, `debug.layout_counters` `scroll_routes`). What the layout takes stays
/// the same (`LayoutScrollModifierTests`).
@MainActor
struct LayoutScrollPassThroughTests {
    typealias Fixture = LayoutScrollModifierTests

    /// A Chromium page window over `pane` of `w`, and the pane's center in window coordinates.
    static func page(over pane: PaneID, of w: Fixture.Window) throws -> (NSWindow, CGPoint) {
        let frame = try #require(w.root.frame(of: pane))
        let page = Fixture.pageWindow()
        Fixture.attach(page, to: w.window, over: w.root.convert(frame, to: nil))
        return (page, try w.center(pane))
    }

    /// A trackpad gesture from `window` at `point`: touch, began, three changes, end, a coast of
    /// momentum, then a wheel notch. Returns how many of its 9 events the layout took.
    static func gesture(_ root: LayoutRootView, from window: NSWindow, at point: CGPoint, dx: Int32 = 0, dy: Int32 = 0) -> Int {
        var taken = 0
        func take(_ wasTaken: Bool) { if wasTaken { taken += 1 } }
        take(Fixture.scroll(root, from: window, at: point, phase: .mayBegin))
        take(Fixture.scroll(root, from: window, at: point, dx: dx, dy: dy, phase: .began))
        for _ in 0..<3 { take(Fixture.scroll(root, from: window, at: point, dx: dx, dy: dy, phase: .changed)) }
        take(Fixture.scroll(root, from: window, at: point, phase: .ended))
        take(Fixture.scroll(root, from: window, at: point, dx: dx / 2, dy: dy / 2, momentum: .begin))
        take(Fixture.scroll(root, from: window, at: point, momentum: .end))
        take(Fixture.scroll(root, from: window, at: point, dy: -1, units: .line))
        return taken
    }

    @Test(arguments: [LayoutScrollModifier.command, .noModifier])
    func aPlainPageScrollTakesNoRouting(modifier: LayoutScrollModifier) throws {
        let w = Fixture.Window(modifier: modifier)
        let (page, point) = try Self.page(over: "top", of: w)
        defer { w.window.removeChildWindow(page); page.close() }
        let before = (routes: w.root.routedScrolls, conversions: w.root.scrollPointConversions)
        #expect(Self.gesture(w.root, from: page, at: point, dy: -30) == 0, "a page's vertical scroll is the page's")
        #expect(Self.gesture(w.root, from: page, at: point, dx: -30) == 0, "a page's sideways scroll is the page's")
        #expect(w.root.routedScrolls == before.routes, "no event reached a hit test or a claim query")
        #expect(w.root.scrollPointConversions == before.conversions, "no event's point was converted")
        #expect(!w.root.ownsCurrentScrollGesture)
    }

    /// The touch decides on the fast path as on the full route: Command pressed after a page's
    /// touch still leaves the gesture to the page.
    @Test func commandPressedAfterAPagesTouchLeavesTheGestureToThePage() throws {
        let w = Fixture.Window(modifier: .command)
        let (page, point) = try Self.page(over: "top", of: w)
        defer { w.window.removeChildWindow(page); page.close() }
        let start = try #require(w.root.frame(of: "p2"))
        #expect(!Fixture.scroll(w.root, from: page, at: point, phase: .mayBegin))
        #expect(!Fixture.scroll(w.root, from: page, at: point, dx: -20, phase: .began, command: true))
        for _ in 0..<3 { #expect(!Fixture.scroll(w.root, from: page, at: point, dx: -20, phase: .changed, command: true)) }
        #expect(!Fixture.scroll(w.root, from: page, at: point, phase: .ended, command: true))
        w.settle()
        #expect(w.root.frame(of: "p2") == start, "the strip did not move")
        // The next gesture with Command at its touch is the layout's again.
        let routed = w.root.routedScrolls
        let converted = w.root.scrollPointConversions
        #expect(Fixture.scroll(w.root, from: page, at: point, phase: .mayBegin, command: true))
        #expect(Fixture.scroll(w.root, from: page, at: point, dx: -20, phase: .began, command: true))
        for _ in 0..<3 { #expect(Fixture.scroll(w.root, from: page, at: point, dx: -20, phase: .changed)) }
        #expect(Fixture.scroll(w.root, from: page, at: point, phase: .ended))
        #expect(w.root.routedScrolls == routed + 6, "every event of a layout gesture takes the full route")
        #expect(w.root.scrollPointConversions == converted + 6, "and converts its point from the page")
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < start.minX - 30, "Command + scroll from a page pans the strip")
    }

    /// In the layout's own window a plain gesture over a pane routes only the events that decide
    /// (its began and end); its changes and coast go on in O(1).
    @Test func aPlainGestureOverAPaneRoutesOnlyItsDecidingEvents() throws {
        let w = Fixture.Window(modifier: .command)
        let point = try w.center("p2")
        let before = w.root.routedScrolls
        let converted = w.root.scrollPointConversions
        let taken = Self.gesture(w.root, from: w.window, at: point, dx: -20)
        #expect(taken == 0, "a plain scroll over a pane is the pane's")
        // The touch, began, end and wheel notch decide; the three changes and the coast do not.
        #expect(w.root.routedScrolls == before + 4)
        #expect(w.root.scrollPointConversions == converted, "the layout's own window needs no conversion")
    }

    /// Focus follows mouse needs the pane under the pointer: with it on, a page's plain scroll takes
    /// the full route and focuses the pane under it.
    @Test func focusFollowsMouseStillFocusesThePageScrolledPane() throws {
        let w = Fixture.Window(modifier: .command, focusFollowsMouse: true)
        let (page, point) = try Self.page(over: "p2", of: w)
        defer { w.window.removeChildWindow(page); page.close() }
        #expect(w.model.focusedPane == "top")
        #expect(!Fixture.scroll(w.root, from: page, at: point, dy: -20, phase: .began))
        #expect(w.model.focusedPane == "p2")
        #expect(!Fixture.scroll(w.root, from: page, at: point, phase: .ended))
    }
}
