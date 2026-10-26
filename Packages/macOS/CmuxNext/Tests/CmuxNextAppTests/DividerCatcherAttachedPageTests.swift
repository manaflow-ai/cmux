import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// p03-rendering-051: divider catcher panels exist only while a page window takes the mouse (a page drawn
/// in its own child window, or a layer-hosted page's input window). A page attached as a view of its pane
/// (p03-rendering-045, Chrome's `RenderWidgetHostViewCocoa` as a subview) has no visible window: the
/// divider views above it take the mouse in the window, as over a terminal, and no catcher, panel or
/// window move is made. A remote page's popup (`ContentChildPanel`) is no page window: a catcher over it
/// took its clicks.
@MainActor @Suite(.serialized) struct DividerCatcherAttachedPageTests {
    final class Panes: LayoutPaneContentProvider {
        /// Stands in for a page attached as a view: an ordinary subview of the pane that takes every hit.
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A shown shell window whose content is a layout of two side-by-side panes, its overlay layer
    /// adopting the layout's plane, as the app wires them; the test drives the frames.
    struct Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let provider = Panes()

        init() {
            _ = NSApplication.shared
            let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))], activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            window.orderFrontRegardless()
            settle()
            window.overlayLayer.evaluate()
        }

        func settle() {
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
        }

        /// Adds a third pane: the divider springs and a new one grows in, then the layout lands.
        func splitAgain() {
            let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                        b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
            root.syncWithModel()
            settle()
        }

        func resizeWindow() {
            var frame = window.frame
            frame.size.width -= 80
            window.setFrame(frame, display: false)
            root.layoutSubtreeIfNeeded()
        }

        /// A child window over the left pane, shown with the parent, as the fork adds a page window.
        func addChild(_ child: NSWindow) {
            child.isReleasedWhenClosed = false
            child.setFrame(CGRect(x: window.frame.minX, y: window.frame.minY, width: 700, height: 600), display: false)
            window.addChildWindow(child, ordered: .above)
            window.overlayLayer.evaluate()
        }

        func removeChild(_ child: NSWindow) {
            window.removeChildWindow(child)
            child.orderOut(nil)
            window.overlayLayer.evaluate()
        }

        func close() {
            window.overlayLayer.teardown()
            window.orderOut(nil)
            window.close()
        }
    }

    /// No page window: dividers move, the window resizes, and the overlay layer never makes a catcher.
    @Test func attachedPagesMakeNoCatcherPanel() throws {
        let layout = Layout()
        defer { layout.close() }
        let layer = layout.window.overlayLayer
        try #require(!layer.catcherAreas.isEmpty, "the split's divider has a catcher area: \(layer.dividerAreas)")

        layout.splitAgain()
        layout.resizeWindow()

        #expect(!layer.pageWindowsTakeMouse)
        #expect(layer.catchers == nil, "no page window takes the mouse, so no catcher exists")
        #expect((layer.catchers?.panelUpdates ?? 0) == 0)
        #expect(!(layout.window.childWindows ?? []).contains { $0 is DividerMousePanel }, "no catcher panel is a child window")
    }

    /// Over a page attached as a view, a press in a divider's hit area, on its part over the pane, reaches
    /// the divider view in the window.
    @Test func theDividerViewTakesThePressOverAnAttachedPage() throws {
        let layout = Layout()
        defer { layout.close() }
        let area = try #require(layout.window.overlayLayer.dividerAreas.first, "the split has a divider area")
        // Inside the hit area, just off its left edge: over the left pane, past the divider's line.
        let point = CGPoint(x: area.rect.minX + 1, y: area.rect.midY)
        let parent = try #require(layout.root.superview)
        var hit = layout.root.hitTest(parent.convert(point, from: nil))
        var reachesDivider = false
        while let view = hit {
            if view is DividerHandleView { reachesDivider = true; break }
            hit = view.superview
        }
        #expect(reachesDivider, "the press at \(point) in \(area.rect) went to \(String(describing: layout.root.hitTest(parent.convert(point, from: nil))))")
    }

    /// A remote page's popup panel alone lifts the overlay above it but makes no catcher.
    @Test func aContentPanelAloneMakesNoCatcher() {
        let layout = Layout()
        defer { layout.close() }
        let popup = ContentChildPanel()
        layout.addChild(popup)
        defer { layout.removeChild(popup) }
        let layer = layout.window.overlayLayer

        #expect(layer.placement == .overlayWindow, "the popup is page content: the overlay goes above it")
        #expect(!layer.pageWindowsTakeMouse)
        #expect(layer.catchers == nil, "a catcher over the popup would take its clicks")
    }

    /// The fallback: a page window gets one panel per catcher area, and they go when it hides.
    @Test func aPageWindowGetsCatchersUntilItHides() throws {
        let layout = Layout()
        defer { layout.close() }
        let layer = layout.window.overlayLayer
        let page = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        layout.addChild(page)

        #expect(layer.pageWindowsTakeMouse)
        let catchers = try #require(layer.catchers, "a page window takes the mouse: the catchers exist")
        #expect(catchers.shownCount == layer.catcherAreas.count, "one panel per area: \(catchers.shownCount) for \(layer.catcherAreas)")
        #expect(catchers.panelUpdates >= layer.catcherAreas.count)

        layout.removeChild(page)
        #expect(!layer.pageWindowsTakeMouse)
        #expect(catchers.shownCount == 0, "the page window hid: its catchers went")
        #expect(!(layout.window.childWindows ?? []).contains { $0 is DividerMousePanel })

        // Dividers that move with no page window move no panel.
        let updates = catchers.panelUpdates
        layout.splitAgain()
        #expect(catchers.panelUpdates == updates)
    }

    /// A page window that appears while a popup already lifted the overlay still gets its catchers.
    @Test func aPageWindowAfterAPopupGetsCatchers() throws {
        let layout = Layout()
        defer { layout.close() }
        let popup = ContentChildPanel()
        layout.addChild(popup)
        defer { layout.removeChild(popup) }
        let page = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        layout.addChild(page)
        defer { layout.removeChild(page) }
        let layer = layout.window.overlayLayer

        #expect(layer.pageWindowsTakeMouse)
        let catchers = try #require(layer.catchers)
        #expect(catchers.shownCount == layer.catcherAreas.count, "\(catchers.shownCount) for \(layer.catcherAreas)")
    }
}
