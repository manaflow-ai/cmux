import AppKit
@testable import CmuxNextBrowser
import Testing

/// The one view every hosted Chromium page shows in: in-process layer hosting
/// and the Chromium host app use the same type; only who takes the page's input differs.
@MainActor
@Suite struct ChromiumHostPageViewTests {
    let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    /// The pages' own center for the window's screen notices: no other test hears this one's.
    let center = NotificationCenter()

    func makePage(_ input: ChromiumHostPageView.InputTarget,
                  layerHost: @escaping (UInt32) -> CALayer? = { _ in CALayer() }) -> ChromiumHostPageView {
        ChromiumHostPageView(frame: frame, inputTarget: input, makeLayerHost: layerHost, windowEventCenter: center)
    }

    /// A window with a stage (the layout root's place) holding a pane holding `page`.
    func makeWindow(holding page: ChromiumHostPageView) -> (NSWindow, stage: NSView, pane: NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let stage = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let pane = NSView(frame: NSRect(x: 20, y: 30, width: 400, height: 300))
        window.contentView?.addSubview(stage)
        stage.addSubview(pane)
        pane.addSubview(page)
        return (window, stage, pane)
    }

    @Test func anInProcessPageLeavesItsInputToThePageWindow() {
        let page = makePage(.pageWindow)
        #expect(page.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(!page.acceptsFirstResponder)
        #expect(!page.acceptsFirstMouse(for: nil))
    }

    @Test func aHostModePageIsItsOwnInputTarget() {
        let page = makePage(.view)
        #expect(page.hitTest(NSPoint(x: 10, y: 10)) === page)
        #expect(page.acceptsFirstResponder)
        #expect(ChromiumHostPageView(frame: frame).inputTarget == .view)
    }

    /// The context shows in the surface, a layer-hosting view with no subviews (AppKit owns
    /// the order of the page view's layers only through its views).
    @Test func theContextShowsInTheSurfaceAndAMissingLayerHostShowsNothing() {
        let page = makePage(.view)
        #expect(page.surface.superview === page)
        #expect(page.surface.subviews.isEmpty)
        #expect(page.surface.frame == page.bounds)
        #expect(page.show(contextID: 9))
        #expect(page.contextID == 9)
        #expect(page.surface.layer?.sublayers?.count == 1)
        #expect(page.show(contextID: 0))
        #expect(page.surface.layer?.sublayers?.isEmpty ?? true)
        #expect(page.surface.subviews.isEmpty)

        let blank = makePage(.pageWindow, layerHost: { _ in nil })
        #expect(!blank.show(contextID: 7))
        #expect(blank.contextID == 0)
    }

    @Test func theBackgroundFillPaintsUnderThePage() {
        let page = makePage(.view)
        #expect(page.surface.layer?.backgroundColor == nil)
        let fill = CGColor(gray: 0.2, alpha: 1)
        page.backgroundFill = fill
        #expect(page.surface.layer?.backgroundColor == fill)
        page.backgroundFill = nil
        #expect(page.surface.layer?.backgroundColor == nil)
    }

    /// Host mode: the crash page covers the page, draws above its pixels and takes the mouse;
    /// clearing the slot gives the page its input back.
    @Test func aHostModeCrashOverlayFillsThePageAboveItsPixelsAndTakesTheMouse() throws {
        let page = makePage(.view)
        #expect(page.show(contextID: 9))
        let crash = NSView()
        crash.wantsLayer = true
        #expect(page.setCrashOverlay(crash))
        #expect(crash.superview === page)
        #expect(crash.frame == page.bounds)
        #expect(page.hitTest(NSPoint(x: 10, y: 10)) === crash)
        // The overlay's layer is above the surface's, which holds the remote layer.
        let layers = try #require(page.layer?.sublayers)
        let surfaceIndex = try #require(layers.firstIndex { $0 === page.surface.layer })
        let crashIndex = try #require(layers.firstIndex { $0 === crash.layer })
        #expect(surfaceIndex < crashIndex)

        let next = NSView()
        #expect(page.setCrashOverlay(next))
        #expect(crash.superview == nil)
        #expect(next.superview === page)

        #expect(page.setCrashOverlay(nil))
        #expect(next.superview == nil)
        #expect(page.crashOverlay == nil)
        #expect(page.hitTest(NSPoint(x: 10, y: 10)) === page)
    }

    /// In process the fork's page window above the pane gets every click in the page's rect, so a
    /// crash overlay there could not be clicked: the slot refuses it rather than show a dead button.
    @Test func anInProcessPageRefusesACrashOverlay() {
        let page = makePage(.pageWindow)
        let crash = NSView()
        #expect(!page.setCrashOverlay(crash))
        #expect(crash.superview == nil)
        #expect(page.crashOverlay == nil)
        #expect(page.subviews.count == 1)
        #expect(page.setCrashOverlay(nil))
    }

    /// P8: the owner hears of the page's screen rect only when it changed. An ancestor that moves
    /// (the layout root, a pane) reaches the page through the window's page update request, the
    /// one the layout owner makes after panes, dividers or the sidebar moved.
    @Test func geometryIsReportedOnlyWhenThePresentedRectChanged() throws {
        let page = makePage(.view)
        var reports: [ChromiumHostGeometry] = []
        page.onGeometry = { reports.append($0) }
        let (window, stage, pane) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        func layoutOwnerPostsPageUpdate() {
            // The window's layout owner (WindowOverlayLayer.requestPageUpdate) asks its pages to update.
            window.updateBrowserPageGeometry()
        }
        #expect(reports.count == 1)
        let first = try #require(reports.first)
        #expect(first.width == 400 && first.height == 300)
        #expect(first.screenX == Int32(window.frame.minX) + 20)
        #expect(first.screenY == Int32(window.frame.minY) + 30)

        // Nothing moved: no report.
        page.setFrameSize(page.frame.size)
        layoutOwnerPostsPageUpdate()
        #expect(reports.count == 1)

        // The pane moved, keeping its size: the page's own frame did not change.
        pane.setFrameOrigin(NSPoint(x: 50, y: 30))
        layoutOwnerPostsPageUpdate()
        #expect(reports.count == 2)
        #expect(reports.last?.screenX == Int32(window.frame.minX) + 50)

        // The layout root moved (a titlebar band change).
        stage.setFrameOrigin(NSPoint(x: 0, y: -10))
        layoutOwnerPostsPageUpdate()
        #expect(reports.count == 3)
        #expect(reports.last?.screenY == Int32(window.frame.minY) + 20)
        layoutOwnerPostsPageUpdate()
        #expect(reports.count == 3)

        // The window moved: its layout owner posts the same request.
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 30, y: window.frame.minY))
        layoutOwnerPostsPageUpdate()
        #expect(reports.count == 4)
        #expect(reports.last?.screenX == Int32(window.frame.minX) + 50)

        page.setFrameSize(NSSize(width: 200, height: 300))
        #expect(reports.count == 5)
        #expect(reports.last?.width == 200)

        // Leaving the window and coming back reports again: the host lost nothing it needs.
        page.removeFromSuperview()
        pane.addSubview(page)
        #expect(reports.count == 6)
    }

    /// The page follows its window only while someone takes its geometry: a taker set after the
    /// page entered its window hears the next page update request.
    @Test func aGeometryTakerSetInAWindowFollowsItsPageUpdates() {
        let page = makePage(.pageWindow)
        let (window, _, pane) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        var reports = 0
        pane.setFrameOrigin(NSPoint(x: 40, y: 30))
        // The window's layout owner (WindowOverlayLayer.requestPageUpdate) asks its pages to update.
        #expect(window.updateBrowserPageGeometry() == 0, "no taker yet: the page is not registered")
        page.onGeometry = { _ in reports += 1 }
        #expect(reports == 0)
        // The window's layout owner (WindowOverlayLayer.requestPageUpdate) asks its pages to update.
        #expect(window.updateBrowserPageGeometry() == 1)
        #expect(reports == 1)
    }

    /// Task 221: the page's display (the host places its detached window there, so begin-frames tick
    /// at that display's rate) is reported when the view enters a window, then only when it changed:
    /// the window's screen and color profile notices, a backing change and the app's display change
    /// re-read it, as Chrome's page view re-reads its screen infos and sends them only when they differ
    /// (`-[RenderWidgetHostViewCocoa updateScreenProperties]`).
    @Test func theDisplayIsReportedOnlyWhenItChanged() throws {
        let page = makePage(.view)
        var display = ChromiumHostScreenInfo(displayID: 1, scaleMilli: 2_000, colorSpaceHash: 7, maximumFramesPerSecond: 120,
                                             workArea: CGRect(x: 0, y: 0, width: 1512, height: 944))
        page.screenInfoSource = { _ in display }
        var reports: [ChromiumHostScreenInfo] = []
        page.onScreenInfo = {
            reports.append($0)
            return true
        }
        #expect(reports.isEmpty, "no window: no display")
        #expect(page.pageDisplay == nil)
        let (window, _, pane) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        #expect(reports == [display])
        let placed = try #require(page.pageDisplay)
        let origin = try #require(page.presentedScreenRect?.origin)
        #expect(placed == ChromiumHostPageDisplay(displayID: 1, screenX: Double(origin.x), screenY: Double(origin.y)))

        // Notices with nothing changed: no report.
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        page.screenParametersChanged()
        page.viewDidChangeBackingProperties()
        #expect(reports.count == 1)

        // The window moved to a 60 Hz display.
        display.displayID = 2
        display.maximumFramesPerSecond = 60
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(reports.count == 2)
        #expect(reports.last == display)
        #expect(page.pageDisplay?.displayID == 2)

        // The same display's refresh rate changed (a display mode change).
        display.maximumFramesPerSecond = 120
        page.screenParametersChanged()
        #expect(reports.count == 3)

        // Its color profile changed.
        display.colorSpaceHash = 9
        center.post(name: NSWindow.didChangeScreenProfileNotification, object: window)
        #expect(reports.count == 4)

        // A 2x to 1x move that AppKit reports as a backing change.
        display.scaleMilli = 1_000
        page.viewDidChangeBackingProperties()
        #expect(reports.count == 5)
        #expect(reports.last?.scaleMilli == 1_000)

        // Leaving the window drops the display; coming back reports it again.
        page.removeFromSuperview()
        #expect(page.screenInfo == nil)
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(reports.count == 5, "out of the window: its notices are not the page's")
        pane.addSubview(page)
        #expect(reports.count == 6)
    }

    /// A placement that could not go out (no page shown in the view yet, a view below 1 x 1 point) is
    /// not recorded: the next chance sends it, even on the same display, and only then does the
    /// dedupe hold.
    @Test func aPlacementThatDidNotGoOutIsSentAtTheNextChance() {
        let page = makePage(.view)
        page.setFrameSize(.zero)
        let display = ChromiumHostScreenInfo(displayID: 3, scaleMilli: 1_000, colorSpaceHash: 7, maximumFramesPerSecond: 60,
                                             workArea: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        page.screenInfoSource = { _ in display }
        var placeable = false
        var asked = 0
        var placed = 0
        page.onScreenInfo = { [weak page] _ in
            asked += 1
            guard placeable, page?.pageDisplay != nil else { return false }
            placed += 1
            return true
        }
        let (window, _, _) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        #expect(asked == 1)
        #expect(placed == 0)
        #expect(page.placedScreenInfo == nil)

        // The same display again: asked again, as nothing went out.
        placeable = true
        page.screenParametersChanged()
        #expect(asked == 2)
        #expect(placed == 0, "below 1 x 1 point: no page display")

        // The view takes a size: the placement goes out, once.
        page.setFrameSize(NSSize(width: 300, height: 200))
        #expect(placed == 1)
        #expect(page.placedScreenInfo == display)
        page.screenParametersChanged()
        page.setFrameSize(NSSize(width: 320, height: 200))
        #expect(asked == 3)
    }

    /// Nobody takes the display: the page view reads no screen and follows no notice.
    @Test func noDisplayTakerReadsNoScreen() {
        let page = makePage(.view)
        var reads = 0
        page.screenInfoSource = { _ in
            reads += 1
            return nil
        }
        let (window, _, _) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        page.screenParametersChanged()
        #expect(reads == 0)
        #expect(page.screenEvents.isEmpty)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test func firstResponderSendsFocusToTheHost() {
        let page = makePage(.view)
        var focus: [Int32] = []
        page.sink = { frame in
            if frame.kind == .focus { focus.append(frame.v[0]) }
            return nil
        }
        let (window, _, _) = makeWindow(holding: page)
        defer { page.removeFromSuperview(); window.close() }
        #expect(window.makeFirstResponder(page))
        #expect(window.makeFirstResponder(nil))
        #expect(focus == [1, 0])
    }

    /// A trackpad scroll from the window server (gesture `scrollPhase`, momentum `momentumPhase`, CG values).
    static func trackpadScroll(scrollPhase: Int64, momentumPhase: Int64, pointDeltaY: Int32) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pointDeltaY,
                                      wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        cg.flags = .maskShift
        return try #require(NSEvent(cgEvent: cg))
    }

    /// The page view sends the event's phases, precise flag and
    /// scrolling deltas. Before, it sent the integer point deltas only.
    @Test func aWheelCarriesItsPhasesAndPreciseDeltas() throws {
        let page = makePage(.view)
        var wheels: [ChromiumHostFrame.Wheel] = []
        page.sink = { frame in
            if let wheel = frame.wheelFields { wheels.append(wheel) }
            return nil
        }
        let gesture = try Self.trackpadScroll(scrollPhase: 2, momentumPhase: 0, pointDeltaY: -12)  // kCGScrollPhaseChanged
        let momentum = try Self.trackpadScroll(scrollPhase: 0, momentumPhase: 1, pointDeltaY: -30)  // kCGMomentumScrollPhaseBegin
        try #require(gesture.phase == .changed && gesture.momentumPhase.isEmpty)
        try #require(momentum.phase.isEmpty && momentum.momentumPhase == .began)
        page.scrollWheel(with: gesture)
        page.scrollWheel(with: momentum)
        try #require(wheels.count == 2)
        #expect(wheels.map(\.phase) == [NSEvent.Phase.changed.rawValue, 0])
        #expect(wheels.map(\.momentumPhase) == [0, NSEvent.Phase.began.rawValue])
        #expect(wheels.map(\.precise) == [gesture.hasPreciseScrollingDeltas, momentum.hasPreciseScrollingDeltas])
        let sentDeltas: [Double] = [gesture, momentum].map { (event: NSEvent) -> Double in (Double(event.scrollingDeltaY) * 100).rounded() / 100 }
        let wheelDeltas: [Double] = wheels.map(\.deltaY)
        #expect(wheelDeltas == sentDeltas)
        let allShifted = wheels.allSatisfy { NSEvent.ModifierFlags(rawValue: UInt($0.modifierFlags)).contains(.shift) }
        #expect(allShifted)
    }
    #endif
}
