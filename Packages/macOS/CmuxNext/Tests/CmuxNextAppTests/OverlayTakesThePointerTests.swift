import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A toast over a pane divider (user 2026-11-16, video "CleanShot 2026-11-16 at 12.42.46 AM"): the pointer on the
/// toast still showed the divider's resize cursor and a drag that started on the toast resized the panes. "We need to
/// make sure toasts z index is proper even for mouse stuff": where an overlay takes the mouse, nothing under it may
/// react, through any path (the window server's window order, and the parent window's own pointer followers).
///
/// Two holes, both seen live on cmux-lawrence-2 at b74f460:
/// - over a page, the divider's mouse-catcher panel was ordered above the overlay panel, so it took the pointer;
/// - with no page, the pane under the toast still followed the pointer (its cursor, its moves).
@MainActor @Suite(.serialized, .closesItsWindows) struct OverlayTakesThePointerTests {
    /// Pane content that records what the screen's pointer tracking tells it.
    final class FollowingPane: NSView, PanePointerFollowing {
        var heard: [String] = []
        func panePointerCursor(at point: NSPoint) -> NSCursor? {
            heard.append("cursor")
            return .iBeam
        }
        func panePointerEntered(with event: NSEvent) { heard.append("entered") }
        func panePointerMoved(with event: NSEvent) { heard.append("moved") }
        func panePointerExited(with event: NSEvent) { heard.append("exited") }
        override func rightMouseDown(with event: NSEvent) { heard.append("rightMouseDown") }
        override func otherMouseDown(with event: NSEvent) { heard.append("otherMouseDown") }
        override func scrollWheel(with event: NSEvent) { heard.append("scrollWheel") }
        override func mouseDown(with event: NSEvent) { heard.append("mouseDown") }
    }

    /// A page window's content that records the presses and scrolls it gets.
    final class RecordingPage: NSView {
        var heard: [String] = []
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        override func rightMouseDown(with event: NSEvent) { heard.append("rightMouseDown") }
        override func mouseDown(with event: NSEvent) { heard.append("mouseDown") }
        override func scrollWheel(with event: NSEvent) { heard.append("scrollWheel") }
    }

    final class Panes: LayoutPaneContentProvider {
        var views: [PaneID: FollowingPane] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let view = FollowingPane()
            views[pane] = view
            return view
        }
    }

    static let two: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    static let three: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                         b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    /// A shown shell window with two panes side by side, a page child window over its content when `withPage`
    /// (as the Chromium fork adds one), and a toast that stays, bottom-centered over the divider.
    final class Scene {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        private(set) var page: NSWindow?
        let panes = Panes()
        let pageContent = RecordingPage()
        let center: CmuxToastCenter

        init(withPage: Bool, toastFirst: Bool = false) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(OverlayTakesThePointerTests.two))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: panes)
            root.context.reduceMotionOverride = true
            window = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            let suite = "cmux.overlayTakesThePointer.\(UUID().uuidString)"
            center = CmuxToastCenter(clock: ContinuousClock(), host: CmuxToastOverlayHost(reduceTransparency: .alwaysOpaque),
                                     styles: CmuxToastStyleStore(defaults: UserDefaults(suiteName: suite)!))
            if toastFirst { showToast() }
            if withPage {
                let page = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                page.isReleasedWhenClosed = false
                page.contentView = pageContent
                window.addChildWindow(page, ordered: .above)
                self.page = page
            }
            window.overlayLayer.evaluate()
            land()
            if !toastFirst { showToast() }
        }

        func showToast() {
            center.show(CmuxToast(id: "hint", message: "Option or Shift + drag selects text", duration: CmuxToast.untilClosed),
                        in: window)
        }

        func land() {
            var moving = true
            var frames = 0
            while moving, frames < 600 {
                moving = root.advanceFrame(1.0 / 120)
                frames += 1
            }
        }

        func close() {
            window.overlayLayer.teardown() // as WindowController.teardown does when the window closes: its catcher panels close
            PointerHover.debugPointers[ObjectIdentifier(window)] = nil
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            if let page {
                window.removeChildWindow(page)
                page.close()
            }
            window.close()
            panel?.close()
        }

        var overlayPanel: NSWindow { WindowOverlayHost.host(for: window).panel }

        /// The toast's frame in window coordinates.
        func toastFrame() throws -> NSRect {
            var pending: [NSView] = overlayPanel.contentView.map { [$0] } ?? []
            while let view = pending.popLast() {
                if view is CmuxToastView { return view.convert(view.bounds, to: nil) }
                pending.append(contentsOf: view.subviews)
            }
            throw ToastMissing()
        }
        struct ToastMissing: Error {}

        /// The divider's center in window coordinates.
        func dividerCenter() throws -> NSPoint {
            try #require(root.debugDividerCenter(named: "first"), "the split shows no divider")
        }

        /// A point on the toast, over the divider (window coordinates).
        func toastOverDivider() throws -> NSPoint {
            let toast = try toastFrame(), divider = try dividerCenter()
            try #require(toast.minX < divider.x && divider.x < toast.maxX, "the toast \(toast) is not over the divider at \(divider.x)")
            return NSPoint(x: divider.x, y: toast.midY)
        }

        /// The visible divider catcher panels (over the page).
        var catchers: [NSWindow] {
            (window.childWindows ?? []).filter { $0 is DividerMousePanel && $0.isVisible && $0.frame.width > 0 }
        }

        var screen: ScreenContentView { root.screenViews.values.first! }

        /// A press of `type` at `point` (window coordinates) addressed to `target` (the window or the page).
        func press(_ type: NSEvent.EventType, at point: NSPoint, to target: NSWindow) -> NSEvent {
            let location = target.convertPoint(fromScreen: window.convertPoint(toScreen: point))
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func moved(to point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
    }

    // MARK: The window order

    /// Over a page, the divider's mouse catcher sits under the overlay panel: a toast over the divider takes the
    /// pointer, not the catcher (the window server gives the pointer to the front window that takes it).
    @Test func aDividerCatcherSitsUnderTheOverlayPanel() throws {
        let scene = Scene(withPage: true)
        defer { scene.close() }
        _ = try scene.toastOverDivider()
        let catchers = scene.catchers
        try #require(!catchers.isEmpty, "no catcher panel over the divider")
        let children = scene.window.childWindows ?? []
        let panelIndex = try #require(children.firstIndex { $0 === scene.overlayPanel })
        for catcher in catchers {
            let index = try #require(children.firstIndex { $0 === catcher })
            #expect(index < panelIndex, "a divider catcher is above the overlay panel: it takes the pointer on the toast")
        }
        if let page = scene.page, let pageIndex = children.firstIndex(where: { $0 === page }) {
            for catcher in catchers {
                #expect(children.firstIndex { $0 === catcher }! > pageIndex, "a divider catcher fell under the page")
            }
        }
    }

    /// The same when the toast came first and the catcher after it (a page shown in a pane under a toast).
    @Test func aCatcherMadeUnderAShownToastStaysUnderIt() throws {
        let scene = Scene(withPage: true, toastFirst: true)
        defer { scene.close() }
        scene.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(OverlayTakesThePointerTests.three))])
        scene.root.syncWithModel()
        scene.land()
        let catchers = scene.catchers
        try #require(catchers.count >= 2, "the three panes show \(catchers.count) catcher panels")
        let children = scene.window.childWindows ?? []
        let panelIndex = try #require(children.firstIndex { $0 === scene.overlayPanel })
        for catcher in catchers {
            #expect(children.firstIndex { $0 === catcher }! < panelIndex, "a new divider catcher went above the overlay panel")
        }
    }

    /// The catcher hears no enter where the toast takes the pointer: no resize cursor, no divider hover line.
    @Test func aCatcherUnderTheToastShowsNoResizeCursor() throws {
        let scene = Scene(withPage: true)
        defer { scene.close() }
        let point = try scene.toastOverDivider()
        var hovers: [Bool] = []
        scene.window.overlayLayer.catchers.onHover = { _, hovered in hovers.append(hovered) }
        let catcher = try #require(scene.catchers.first as? DividerMousePanel)
        let screenPoint = scene.window.convertPoint(toScreen: point)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: catcher.convertPoint(fromScreen: screenPoint),
                                                        modifierFlags: [], timestamp: 0, windowNumber: catcher.windowNumber,
                                                        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        catcher.catcher.mouseEntered(with: event)
        #expect(hovers.allSatisfy { !$0 }, "the divider under the toast lit its hover line")
    }

    // MARK: The parent window's pointer followers

    /// The divider under the toast does not hover (no resize cursor, no lit line), with or without a page.
    @Test(arguments: [false, true])
    func theDividerUnderAToastDoesNotHover(withPage: Bool) throws {
        let scene = Scene(withPage: withPage)
        defer { scene.close() }
        let point = try scene.toastOverDivider()
        LayoutRootView.setDebugPointer(point, in: scene.window, layouts: [scene.root])
        let hovered = scene.screen.dividerViews.values.contains { $0.isHovered }
        #expect(!hovered, "the divider under the toast hovers: it shows its resize cursor through the toast")
        // The same divider away from the toast hovers (the harness reaches it).
        let divider = try scene.dividerCenter()
        LayoutRootView.setDebugPointer(NSPoint(x: divider.x, y: 600), in: scene.window, layouts: [scene.root])
        #expect(scene.screen.dividerViews.values.contains { $0.isHovered }, "the divider away from the toast does not hover")
    }

    /// The pane under the toast hears nothing of the pointer on the toast: no enter, no moves, no I-beam cursor.
    @Test func thePaneUnderAToastDoesNotFollowThePointer() throws {
        let scene = Scene(withPage: false)
        defer { scene.close() }
        let toast = try scene.toastFrame(), divider = try scene.dividerCenter()
        let onToast = NSPoint(x: divider.x - 60, y: toast.midY)
        try #require(toast.contains(onToast))
        let pane = try #require(scene.panes.views["p1"])
        scene.screen.dividerPointer.mouseMoved(with: scene.moved(to: onToast))
        #expect(pane.heard.isEmpty, "the pane under the toast heard \(pane.heard)")
        // Off the toast, the pane follows the pointer again (the harness reaches it).
        scene.screen.dividerPointer.mouseMoved(with: scene.moved(to: NSPoint(x: divider.x - 60, y: 600)))
        #expect(pane.heard.contains("entered"), "the pane away from the toast heard \(pane.heard)")
    }

    // MARK: Presses and scrolls that reach a window under the overlay

    /// The overlay panel takes the mouse only after a move the app sees switched it on: with the cmux window in the
    /// background, or a pointer that did not move, the window server gives a press or a scroll on the toast to the
    /// window under it (live on cmux-lawrence-2 at 3ede87f: a right-click on the toast opened the terminal pane's menu
    /// and the divider's menu, a scroll on it scrolled the terminal). The window passes such an event to the overlay.
    ///
    /// The press lands on the toast's padding, not its text: the text is selectable, and a right-click there opens the
    /// text's own menu, whose tracking loop waits for a person. A scroll is checked live (a test cannot make a scroll
    /// event addressed to a window), as is a left press (the pane's own views take it before the pane does).
    @Test(arguments: [NSEvent.EventType.rightMouseDown, .otherMouseDown])
    func aPressOnTheToastThatReachesTheWindowDoesNotReachThePane(type: NSEvent.EventType) throws {
        let scene = Scene(withPage: false)
        defer { scene.close() }
        let toast = try scene.toastFrame(), divider = try scene.dividerCenter()
        let onToast = NSPoint(x: toast.minX + 5, y: toast.midY)
        try #require(onToast.x < divider.x - 10)
        let pane = try #require(scene.panes.views["p1"])
        scene.overlayPanel.ignoresMouseEvents = true // no move switched the panel on
        scene.window.sendEvent(scene.press(type, at: onToast, to: scene.window))
        #expect(pane.heard.filter { $0.hasSuffix("MouseDown") }.isEmpty, "the pane under the toast heard \(pane.heard)")
        // Off the toast, the pane gets the press (the harness reaches it).
        scene.window.sendEvent(scene.press(type, at: NSPoint(x: divider.x - 60, y: 600), to: scene.window))
        #expect(!pane.heard.filter { $0.hasSuffix("MouseDown") }.isEmpty, "the pane away from the toast heard \(pane.heard)")
    }

    /// A press on the toast that the window server gives to a page window under it (a Chromium page is a child window,
    /// and the toast's region is not masked out of it) does not reach the page.
    @Test func aPressOnTheToastThatReachesAPageDoesNotReachThePage() throws {
        let scene = Scene(withPage: true)
        defer { scene.close() }
        let toast = try scene.toastFrame()
        let point = NSPoint(x: toast.minX + 5, y: toast.midY)
        let page = try #require(scene.page)
        scene.overlayPanel.ignoresMouseEvents = true
        NSApp.sendEvent(scene.press(.rightMouseDown, at: point, to: page))
        #expect(scene.pageContent.heard.isEmpty, "the page under the toast heard \(scene.pageContent.heard)")
        // Off the toast, the page gets it (the harness reaches it).
        NSApp.sendEvent(scene.press(.rightMouseDown, at: NSPoint(x: point.x, y: 600), to: page))
        #expect(scene.pageContent.heard == ["rightMouseDown"], "the page away from the toast heard \(scene.pageContent.heard)")
    }
}
