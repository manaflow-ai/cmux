import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Pointer events that a helper window of the main window took and passed on to the wrong window (a127's findings on
/// cmux#45851, 2026-11-17). A main window has three kinds of helper windows over its content: the overlay panel
/// (dialogs, toasts), divider catchers (``DividerMousePanel``, over every divider a Chromium page covers) and one
/// window per Chromium page. Each passed an event on by its own rule:
///
/// - a scroll in a divider catcher went straight to the view of the main window under it, by a hit test that ran no
///   window's `sendEvent`: over a page, the pane hidden under the page got it and the page, which the person sees
///   there, got nothing;
/// - a press the overlay panel passed on (it still took the mouse where no overlay was) went to the page under the
///   point, never to a divider catcher there: the divider never got its press and the page got a click;
/// - a scroll that reached the overlay panel where no overlay takes the mouse went nowhere.
@MainActor @Suite(.serialized, .closesItsWindows) struct HelperWindowEventRoutingTests {
    typealias Scene = OverlayTakesThePointerTests.Scene

    /// A trackpad scroll at `screen`, as the window server makes one (its global location is the point).
    static func scroll(at screen: NSPoint) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let height = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        return try #require(NSEvent(cgEvent: cg))
    }

    /// The visible divider catcher over the split's divider.
    static func catcher(in scene: Scene) throws -> DividerMousePanel {
        try #require(scene.catchers.first as? DividerMousePanel, "no catcher panel over the divider")
    }

    /// A point in `catcher` away from the toast (the toast sits at the bottom), `x` in screen coordinates.
    static func pointInCatcher(_ catcher: NSWindow, x: CGFloat, scene: Scene) -> NSPoint {
        NSPoint(x: x, y: scene.window.convertToScreen(NSRect(x: 0, y: 600, width: 1, height: 1)).minY)
    }

    static func scrolls(_ heard: [String]) -> Int { heard.filter { $0 == "scrollWheel" }.count }

    // MARK: A scroll in a divider catcher

    /// The page fills the window: a scroll in the catcher scrolls the page the person sees there, not the pane hidden
    /// under it.
    @Test func aScrollInADividerCatcherOverAPageScrollsThePage() throws {
        let scene = Scene(withPage: true)
        defer { scene.close() }
        let catcher = try Self.catcher(in: scene)
        let point = Self.pointInCatcher(catcher, x: catcher.frame.midX, scene: scene)
        catcher.catcher.scrollWheel(with: try Self.scroll(at: point))
        #expect(Self.scrolls(scene.pageContent.heard) == 1, "the page under the catcher heard \(scene.pageContent.heard)")
        for (pane, view) in scene.panes.views {
            #expect(Self.scrolls(view.heard) == 0, "pane \(pane), hidden under the page, got the scroll")
        }
    }

    /// The page covers only the right pane: the catcher's half over the left pane scrolls that pane, its half over the
    /// page scrolls the page.
    @Test func aScrollInADividerCatcherGoesToWhatIsUnderItsPoint() throws {
        let scene = Scene(withPage: true)
        defer { scene.close() }
        let page = try #require(scene.page)
        let divider = try scene.dividerCenter()
        let right = NSRect(x: divider.x, y: 0, width: scene.window.frame.width - divider.x,
                           height: scene.window.contentLayoutRect.height)
        page.setFrame(scene.window.convertToScreen(right), display: false)
        scene.window.overlayLayer.evaluate()
        scene.land()
        let catcher = try Self.catcher(in: scene)
        try #require(catcher.frame.minX < page.frame.minX && page.frame.minX < catcher.frame.maxX,
                     "the catcher \(catcher.frame) does not straddle the page's edge \(page.frame.minX)")
        let left = try #require(scene.panes.views["p1"])

        catcher.catcher.scrollWheel(with: try Self.scroll(at: Self.pointInCatcher(catcher, x: catcher.frame.minX + 1, scene: scene)))
        #expect(Self.scrolls(left.heard) == 1, "the left pane under the catcher heard \(left.heard)")
        #expect(Self.scrolls(scene.pageContent.heard) == 0)

        catcher.catcher.scrollWheel(with: try Self.scroll(at: Self.pointInCatcher(catcher, x: catcher.frame.maxX - 1, scene: scene)))
        #expect(Self.scrolls(scene.pageContent.heard) == 1, "the page under the catcher heard \(scene.pageContent.heard)")
        #expect(Self.scrolls(left.heard) == 1, "the left pane got the page's scroll too")
    }

    // MARK: What the overlay panel passes on

    /// The panel still takes the mouse where no overlay is (no move switched it off yet): a press there over a divider
    /// goes to the divider's catcher, and so to the divider, not to the page under the catcher.
    @Test func aPressThePanelPassesOnOverADividerReachesTheDivider() throws {
        let scene = Scene(withPage: true)
        defer { scene.close() }
        let catcher = try Self.catcher(in: scene)
        let host = WindowOverlayHost.host(for: scene.window)
        let screen = Self.pointInCatcher(catcher, x: catcher.frame.midX, scene: scene)
        let point = scene.window.convertPoint(fromScreen: screen)
        try #require(!WindowOverlayHost.overlayTakesMouse(in: scene.window, atWindowPoint: point), "the point is on the toast")
        scene.overlayPanel.ignoresMouseEvents = false
        scene.window.overlayLayer.catchers.isLeftButtonDown = { true }
        #expect(host.panelMouseEvent(scene.press(.leftMouseDown, at: point, to: scene.overlayPanel)), "the panel passed the press on")
        #expect(catcher.catcher.isPressed, "the divider's catcher did not get the press")
        #expect(!scene.pageContent.heard.contains("mouseDown"), "the page under the divider got the press")
        _ = host.panelMouseEvent(scene.press(.leftMouseUp, at: point, to: scene.overlayPanel))
        #expect(!catcher.catcher.isPressed, "the release did not follow the press to the catcher")
    }

    /// A scroll that reaches the panel where no overlay takes the mouse goes on to the page under it.
    @Test func aScrollThatReachesThePanelOffEveryOverlayScrollsThePageUnderIt() throws {
        let scene = Scene(withPage: true)
        defer { scene.close() }
        let host = WindowOverlayHost.host(for: scene.window)
        let point = NSPoint(x: 200, y: 600)
        try #require(!WindowOverlayHost.overlayTakesMouse(in: scene.window, atWindowPoint: point), "the point is on the toast")
        scene.overlayPanel.ignoresMouseEvents = false
        let event = try Self.scroll(at: scene.window.convertPoint(toScreen: point))
        if !host.panelMouseEvent(event) { scene.overlayPanel.sendEvent(event) }
        #expect(Self.scrolls(scene.pageContent.heard) == 1, "the page under the panel heard \(scene.pageContent.heard)")
    }
}
