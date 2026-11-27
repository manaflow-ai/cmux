import AppKit
@testable import CmuxNextLayout
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Only the pane AppKit gives a press to takes the focus.
///
/// The layout's local mouse-down monitor (`LayoutRootView.handleMonitored`) runs before AppKit
/// dispatches a press, and it focused the pane under every press inside its bounds. Several presses
/// lie over a pane but reach no pane: AppKit keeps a press at the window's edge or corner (inside the
/// frame too) for a window resize, a divider's hit area is wider than the gap between its panes, the
/// sidebar's resize band reaches over the pane beside it, and the titlebar's buttons sit over the
/// top-left pane. Each one moved the focus, so the next keys went to a pane the person never clicked
/// (journey r3-after-switch failed 4 of 4 on v2.2.11-opt after a corner drag, cmux-ad P0 2026-10-31).
@MainActor @Suite(.closesItsWindows)
struct WindowResizePressKeepsFocusTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// The window's content view: the layout fills it, the sidebar's resize band (when added) sits above it,
        /// as `WindowRootView` mounts `SidebarResizeHandle`.
        let content = NSView()

        init(focused: PaneID) {
            _ = NSApplication.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("left"), b: .leaf("right")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: focused)
            root = LayoutRootView(model: model, contentProvider: provider)
            // The shell window's style (WindowController): titled, resizable, full-size content.
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.contentView = content
            root.frame = content.bounds
            root.autoresizingMask = [.width, .height]
            content.addSubview(root)
            root.layoutSubtreeIfNeeded()
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        /// A press at `point` (window base coordinates), as the monitor sees it before AppKit dispatches it.
        func press(at point: CGPoint) { root.handleMonitoredPress(at: point) }

        /// The pane whose rect holds `point` (window base coordinates): what the monitor focused before the fix.
        func paneUnder(_ point: CGPoint) throws -> PaneID? {
            let screen = try screen
            return screen.pane(at: screen.convert(point, from: nil))
        }

        /// What AppKit's own hit test gives at `point`: the view a press there is delivered to.
        func hit(at point: CGPoint) -> String {
            guard let frameView = window.contentView?.superview, let view = frameView.hitTest(frameView.convert(point, from: nil)) else {
                return "nil"
            }
            let place = view === frameView ? "frame" : view.isDescendant(of: root) ? "layout" : view.isDescendant(of: content) ? "content" : "other"
            return "\(type(of: view))(\(place))"
        }

        var size: CGSize { window.frame.size }

        func close() { window.closeAfterTest() }
    }

    /// In a window on screen AppKit's frame view keeps this press for a window resize; in this test's
    /// window (never on screen) the layout's column-edge handle gets it. Either way it reaches no pane.
    /// The frame-view case is proved live by the journeys r3-after-switch and focus-corner-drag.
    @Test func aPressInTheBottomRightResizeCornerLeavesTheFocus() throws {
        let harness = Harness(focused: "left")
        defer { harness.close() }
        let corner = CGPoint(x: harness.size.width - 1, y: 1)
        try #require(try harness.paneUnder(corner) == "right", "the corner must lie over the right pane for this test to mean anything")
        harness.press(at: corner)
        #expect(harness.model.focusedPane == "left",
                "a press in the window's resize corner focused \(String(describing: harness.model.focusedPane)); AppKit's hit test there: \(harness.hit(at: corner))")
    }

    @Test func aPressOnASplitDividerLeavesTheFocus() throws {
        let harness = Harness(focused: "left")
        defer { harness.close() }
        let handle = try #require(try harness.screen.dividerViews[.split("x")])
        // The right part of the divider's hit area: inside the right pane's rect, but the divider takes the press.
        let edge = handle.convert(CGPoint(x: handle.bounds.maxX - 1, y: handle.bounds.midY), to: nil)
        try #require(try harness.paneUnder(edge) == "right", "the divider's hit area must reach over the right pane here (hit width \(handle.bounds.width))")
        harness.press(at: edge)
        #expect(harness.model.focusedPane == "left",
                "a press on the divider focused \(String(describing: harness.model.focusedPane)); AppKit's hit test there: \(harness.hit(at: edge))")
    }

    @Test func aPressOnTheSidebarResizeBandLeavesTheFocus() throws {
        let harness = Harness(focused: "right")
        defer { harness.close() }
        // The sidebar's band sits above the layout and reaches over the pane beside the sidebar (WindowRootView).
        let band = SidebarResizeHandle(frame: CGRect(x: 0, y: 0, width: 8, height: harness.content.bounds.height))
        harness.content.addSubview(band)
        let point = band.convert(CGPoint(x: band.bounds.maxX - 1, y: band.bounds.midY), to: nil)
        try #require(try harness.paneUnder(point) == "left", "the band must lie over the left pane for this test to mean anything")
        harness.press(at: point)
        #expect(harness.model.focusedPane == "right",
                "a press on the sidebar's resize band focused \(String(describing: harness.model.focusedPane)); AppKit's hit test there: \(harness.hit(at: point))")
    }

    @Test func aPressOnTheTitlebarButtonsLeavesTheFocus() throws {
        let harness = Harness(focused: "right")
        defer { harness.close() }
        let close = try #require(harness.window.standardWindowButton(.closeButton))
        let point = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        try #require(try harness.paneUnder(point) == "left", "the close button must lie over the left pane for this test to mean anything")
        harness.press(at: point)
        #expect(harness.model.focusedPane == "right",
                "a press on the titlebar's close button focused \(String(describing: harness.model.focusedPane)); AppKit's hit test there: \(harness.hit(at: point))")
    }

    @Test func aPressInsideAPaneStillFocusesIt() throws {
        let harness = Harness(focused: "left")
        defer { harness.close() }
        let host = try #require(harness.root.context.hosts["right"])
        let center = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        try #require(try harness.paneUnder(center) == "right")
        harness.press(at: center)
        #expect(harness.model.focusedPane == "right", "AppKit's hit test there: \(harness.hit(at: center))")
    }

    /// Not a check: prints where AppKit's hit test sends presses near the window's edges, for the record.
    @Test func reportsAppKitHitTestNearTheEdges() {
        let harness = Harness(focused: "left")
        defer { harness.close() }
        let (w, h) = (harness.size.width, harness.size.height)
        for inset in [0.0, 1, 2, 3, 4, 5, 6, 8, 12] {
            let corner = harness.hit(at: CGPoint(x: w - 1 - inset, y: 1 + inset))
            let right = harness.hit(at: CGPoint(x: w - 1 - inset, y: h / 2))
            let bottom = harness.hit(at: CGPoint(x: w / 2, y: 1 + inset))
            let left = harness.hit(at: CGPoint(x: 1 + inset, y: h / 2))
            print("P0FD-HIT inset \(inset): corner \(corner) right \(right) bottom \(bottom) left \(left)")
        }
    }
}
