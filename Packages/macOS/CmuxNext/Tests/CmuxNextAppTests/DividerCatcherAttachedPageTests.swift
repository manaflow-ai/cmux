import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// Divider catcher panels exist only while a page window takes the mouse (a page drawn
/// in its own child window, or a layer-hosted page's input window). A page attached as a view of its pane
/// (Chrome's `RenderWidgetHostViewCocoa` as a subview) keeps its own window a child that
/// is never ordered in: the divider views above it take the mouse in the window, as over a terminal, and no
/// catcher, panel, window move or catcher sync slice is made. A remote page's popup (`ContentChildPanel`)
/// lies below the catchers: they are cut around it, so it keeps its clicks.
@MainActor @Suite(.serialized) struct DividerCatcherAttachedPageTests {
    final class Panes: LayoutPaneContentProvider {
        /// The pane's view: what an attached page's view is to the layout.
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        /// Begin records of `cef.geometry` slices, by source code.
        var geometrySources: [UInt64] {
            state.withLock { $0.filter { $0.name == SignpostName.cefGeometry.rawValue && $0.phase == .begin }.map(\.arg0) }
        }

        /// End records of `cef.geometry` slices: (catchers shown, panels made or moved).
        var geometryEnds: [(UInt64, UInt64)] {
            state.withLock { $0.filter { $0.name == SignpostName.cefGeometry.rawValue && $0.phase == .end }.map { ($0.arg0, $0.arg1) } }
        }

        func clear() { state.withLock { $0.removeAll() } }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    /// A window that hosts the layout's overlay plane with an overlay layer that records into the test's trace,
    /// as `ShellWindow` hosts it with the app's.
    final class HostWindow: NSWindow, OverlayPlaneHosting {
        var overlay: WindowOverlayLayer?

        override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
            super.addChildWindow(childWin, ordered: place)
            overlay?.evaluate()
        }

        func adoptPlane(_ plane: OverlayPlane) { overlay?.adopt(plane) }
        func releasePlane(_ plane: OverlayPlane) { overlay?.release(plane) }
        func interactiveOverlayRectsDidChange(_ plane: OverlayPlane) { overlay?.interactiveRectsDidChange() }
        func planeDidLayout(_ plane: OverlayPlane) { overlay?.planeDidLayout(plane) }
        func paneShapesDidChange(_ plane: OverlayPlane) { overlay?.paneShapesDidChange() }
    }

    /// A shown window whose content is a layout of two side-by-side panes, its overlay layer adopting the
    /// layout's plane; the test drives the frames.
    struct Layout {
        let log = RecordLog()
        let window: HostWindow
        let layer: WindowOverlayLayer
        let model: LayoutModel
        let root: LayoutRootView
        let provider = Panes()

        init() {
            _ = NSApplication.shared
            let runtime = log.runtime()
            runtime.setCategories(.all)
            let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))], activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = HostWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            layer = WindowOverlayLayer(window: window,
                                       signposter: Signposter(category: .cef, mirror: SignpostMetricKitMirror(), trace: runtime),
                                       currentTurn: { 0 })
            window.overlay = layer
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            window.orderFrontRegardless()
            settle()
            layer.evaluate()
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

        /// A child window over `rect` (window coordinates), shown with the parent, as the fork adds a page window.
        func addChild(_ child: NSWindow, over rect: CGRect = CGRect(x: 0, y: 0, width: 700, height: 600)) {
            child.isReleasedWhenClosed = false
            child.setFrame(window.convertToScreen(rect), display: false)
            window.addChildWindow(child, ordered: .above)
        }

        func removeChild(_ child: NSWindow) {
            window.removeChildWindow(child)
            child.orderOut(nil)
            layer.evaluate()
        }

        var catcherPanels: [NSWindow] { (window.childWindows ?? []).filter { $0 is DividerMousePanel && $0.isVisible } }

        func close() {
            layer.teardown()
            window.orderOut(nil)
            window.close()
        }
    }

    /// With no page window, the overlay layer never makes a catcher.
    @Test func noPageWindowMakesNoCatcher() throws {
        let layout = Layout()
        defer { layout.close() }
        let layer = layout.layer
        try #require(!layer.catcherAreas.isEmpty, "the split's divider has a catcher area: \(layer.dividerAreas)")

        layout.splitAgain()
        layout.resizeWindow()

        #expect(!layer.pageWindowsTakeMouse)
        #expect(layer.catchers == nil, "no page window takes the mouse, so no catcher exists")
        #expect(layout.catcherPanels.isEmpty)
    }

    /// An attached page's own window stays a child of the window, ordered out, as an attached CEF browser
    /// keeps it. While the overlay layer keeps evaluating, dividers move, a pane splits
    /// and the window resizes: no catcher panel shows, none is made or moved, and no catcher sync slice is
    /// taken. Before p03-rendering-051 every divider area change took a `catcherSync` slice, page or not.
    @Test func anAttachedPageMakesNoCatcherWorkWhileTheOverlayEvaluates() throws {
        let layout = Layout()
        defer { layout.close() }
        let layer = layout.layer
        try #require(!layer.catcherAreas.isEmpty, "the split's divider has a catcher area: \(layer.dividerAreas)")
        let page = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        layout.addChild(page)
        page.orderOut(nil)
        layer.evaluate()
        defer { layout.removeChild(page) }
        let updates = layer.catchers?.panelUpdates ?? 0
        layout.log.clear()

        layout.splitAgain()
        layer.evaluate()
        layout.resizeWindow()
        layer.evaluate()

        #expect(!layer.pageWindowsTakeMouse)
        #expect(layout.catcherPanels.isEmpty, "no catcher panel shows")
        #expect((layer.catchers?.panelUpdates ?? 0) == updates, "no catcher panel was made or moved")
        let sources = layout.log.geometrySources
        #expect(!sources.contains(Signposter.CEFGeometrySource.catcherSync.rawValue), "no catcher sync slice: \(sources)")
        #expect(sources.contains(Signposter.CEFGeometrySource.parentGeometry.rawValue), "the resize still took its slice")
        #expect(layout.log.geometryEnds.allSatisfy { $0.0 == 0 && $0.1 == 0 }, "no panel shown, made or moved: \(layout.log.geometryEnds)")
    }

    /// A layer-hosted page's input window (a borderless, clear plain window over the pane) takes the mouse:
    /// the dividers it covers get catchers.
    @Test func aLayerHostedPagesInputWindowGetsCatchers() throws {
        let layout = Layout()
        defer { layout.close() }
        let input = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        input.isOpaque = false
        input.backgroundColor = .clear
        layout.addChild(input)
        defer { layout.removeChild(input) }
        let layer = layout.layer

        #expect(layer.pageWindowsTakeMouse)
        let catchers = try #require(layer.catchers)
        #expect(catchers.shownCount == layer.catcherAreas.count, "\(catchers.shownCount) for \(layer.catcherAreas)")
    }

    /// A remote page's popup panel alone lifts the overlay above it, and no catcher panel covers it.
    @Test func aContentPanelAloneGetsNoCatcherPanel() {
        let layout = Layout()
        defer { layout.close() }
        let popup = ContentChildPanel()
        layout.addChild(popup)
        defer { layout.removeChild(popup) }
        let layer = layout.layer

        #expect(layer.placement == .overlayWindow, "the popup is page content: the overlay goes above it")
        #expect(!layer.pageWindowsTakeMouse)
        #expect(layout.catcherPanels.isEmpty, "a catcher over the popup would take its clicks")
    }

    /// The fallback: a page window gets one panel per catcher area, and they go when it hides.
    @Test func aPageWindowGetsCatchersUntilItHides() throws {
        let layout = Layout()
        defer { layout.close() }
        let layer = layout.layer
        let page = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        layout.addChild(page)

        #expect(layer.pageWindowsTakeMouse)
        let catchers = try #require(layer.catchers, "a page window takes the mouse: the catchers exist")
        #expect(catchers.shownCount == layer.catcherAreas.count, "one panel per area: \(catchers.shownCount) for \(layer.catcherAreas)")
        #expect(catchers.panelUpdates >= layer.catcherAreas.count)

        layout.removeChild(page)
        #expect(!layer.pageWindowsTakeMouse)
        #expect(catchers.shownCount == 0, "the page window hid: its catchers went")
        #expect(layout.catcherPanels.isEmpty)

        // Dividers that move with no page window move no panel.
        let updates = catchers.panelUpdates
        layout.splitAgain()
        #expect(catchers.panelUpdates == updates)
    }

    /// A page window in one pane and a popup over the divider: the divider keeps catchers off the popup and
    /// on the rest of its area, and they cover the whole area again once the popup hides.
    @Test func aPopupOverADividerNextToAPageWindowKeepsItsClicks() throws {
        let layout = Layout()
        defer { layout.close() }
        let layer = layout.layer
        let area = try #require(layer.dividerAreas.first, "the split has a divider area")
        let page = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        layout.addChild(page, over: CGRect(x: area.rect.maxX, y: 0, width: 400, height: 600))
        defer { layout.removeChild(page) }
        let popup = ContentChildPanel()
        // A menu from the left pane reaching across the divider, over its middle.
        let popupRect = CGRect(x: area.rect.minX - 100, y: area.rect.midY - 50, width: 240, height: 100)
        layout.addChild(popup, over: popupRect)
        let catchers = try #require(layer.catchers, "the page window takes the mouse: the catchers exist")

        let popupInWindow = layout.window.convertFromScreen(popup.frame)
        #expect(layer.catcherHoles == [popupInWindow])
        let frames = catchers.framesInWindow.values
        #expect(!frames.isEmpty, "the divider keeps catchers outside the popup")
        #expect(frames.allSatisfy { !$0.intersection(popupInWindow).hasArea }, "no catcher over the popup: \(frames) vs \(popupInWindow)")
        #expect(layout.catcherPanels.allSatisfy { !$0.frame.intersection(popup.frame).hasArea })
        // Above and below the popup, the divider still takes the press.
        #expect(frames.contains { $0.contains(CGPoint(x: area.rect.midX, y: popupInWindow.minY - 2)) })
        #expect(frames.contains { $0.contains(CGPoint(x: area.rect.midX, y: popupInWindow.maxY + 2)) })

        // The popup moves off the divider: the catcher covers the divider area whole again.
        popup.setFrame(layout.window.convertToScreen(popupRect.offsetBy(dx: -400, dy: 0)), display: false)
        layer.evaluate()
        let divider = try #require(catchers.framesInWindow[area.id], "one panel for the whole area: \(catchers.framesInWindow)")
        #expect(divider == area.rect)

        layout.removeChild(popup)
        #expect(layer.catcherHoles.isEmpty)
        #expect(catchers.framesInWindow[area.id] == area.rect)
    }

    /// The cut of an area around a hole: the parts outside it, none overlapping it.
    @Test func anAreaIsCutAroundAHole() {
        let area = LayoutMouseArea(id: "d", rect: CGRect(x: 100, y: 0, width: 10, height: 400), resizesColumns: true)
        let untouched = DividerMouseCatchers.pieces(of: [area], excluding: [CGRect(x: 0, y: 0, width: 50, height: 50)])
        #expect(untouched == [DividerMouseCatchers.Piece(key: "d", area: area)])

        let hole = CGRect(x: 90, y: 100, width: 40, height: 50)
        let pieces = DividerMouseCatchers.pieces(of: [area], excluding: [hole])
        #expect(pieces.map(\.area.rect) == [CGRect(x: 100, y: 0, width: 10, height: 100), CGRect(x: 100, y: 150, width: 10, height: 250)])
        #expect(pieces.map(\.key) == ["d#0", "d#1"])
        #expect(pieces.allSatisfy { $0.area.id == "d" && $0.area.resizesColumns })

        let covered = DividerMouseCatchers.pieces(of: [area], excluding: [CGRect(x: 0, y: -10, width: 500, height: 500)])
        #expect(covered.isEmpty)
    }
}

private extension CGRect {
    var hasArea: Bool { !isNull && width > 0 && height > 0 }
}
