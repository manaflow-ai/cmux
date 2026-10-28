import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing
import WebKit

/// With the `pageSpringResizeOnce` feature a page in a springing pane resizes once, at the
/// spring's start, to the size its pane rests at, and not again at the landing (F12: both engines); a page in
/// its own window hides while its pane shows a render-server move instead of showing at the pane's rest place.
/// `PageSpringPaneHostTests` (CmuxNextAppTests) drives the same pages from a real `PaneHostView`.
@MainActor @Suite(.serialized) struct PageSpringResizeTests {
    /// A pane host as the layout makes it, reduced to what pages read: its spring flag, its rest content size
    /// (the change it reports is the rest less the content's current size, as `PaneHostView.restSizeChange`),
    /// its render-server move and the feature's page resizing.
    final class Placement: NSView, RestingPlacement {
        var restOffset: CGVector = .zero
        var isOnLayoutSpring = false
        /// The content's size at rest while on a spring.
        var rest: CGSize?
        let pageResizing: PageSpringResizing?
        var showsRenderMove = false {
            didSet { if showsRenderMove != oldValue { for view in subviews { view.notifyPaneRenderMoveChanged(showsRenderMove) } } }
        }

        init(frame: CGRect, mode: SpringPageResize) {
            pageResizing = PageSpringResizing(mode: { mode })
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var restContentSizeChange: CGSize? {
            guard isOnLayoutSpring, let rest, let now = subviews.first?.frame.size else { return nil }
            let change = CGSize(width: rest.width - now.width, height: rest.height - now.height)
            return abs(change.width) >= 0.5 || abs(change.height) >= 0.5 ? change : nil
        }

        /// A spring toward `rest` starts and tells the content (`PaneHostView.announceRest`).
        func start(toward rest: CGSize) {
            isOnLayoutSpring = true
            self.rest = rest
            if let content = subviews.first, let change = restContentSizeChange { content.notifyPaneMotionWillRest(sizeChange: change) }
        }

        /// The spring lands.
        func land() {
            isOnLayoutSpring = false
            rest = nil
            for view in subviews { view.notifyPaneMotionSettled() }
        }
    }

    /// A page that counts the sizes it laid out at.
    final class Page: NSView {
        private(set) var sizes: [CGSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    /// The sizes a view took, from its frame change notifications (every `setFrameSize` that changed it).
    @MainActor final class Sizes {
        private(set) var sizes: [CGSize] = []
        private var observer: (any NSObjectProtocol)?

        init(_ view: NSView) {
            sizes = [view.frame.size]
            view.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self, weak view] _ in
                MainActor.assumeIsolated { // main-proof: frame changes post on the thread that set the frame, the test's main thread
                    guard let self, let size = view?.frame.size, size != self.sizes.last else { return }
                    self.sizes.append(size)
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    // MARK: WebKit

    func webKitPage(in pane: Placement) -> (Page, WebKitPageContainer) {
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)
        return (page, container)
    }

    @Test func aWebKitPageResizesOnceAtTheSpringsStartAndNotAtItsLanding() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let (page, container) = webKitPage(in: pane)
        #expect(page.sizes == [CGSize(width: 640, height: 600)])

        // Cmd-D: the pane will rest at half its width.
        pane.start(toward: CGSize(width: 320, height: 600))
        #expect(page.sizes.last == CGSize(width: 320, height: 600), "the page takes its rest size at the start")
        #expect(page.frame.origin == CGPoint(x: 0, y: 0), "held at the top-left")
        // The main thread's spring frames shrink the pane toward its rest.
        for width in [560.0, 480, 400, 320] { container.setFrameSize(NSSize(width: width, height: 600)) }
        pane.land()
        #expect(page.sizes == [CGSize(width: 640, height: 600), CGSize(width: 320, height: 600)],
                "one resize per Cmd-D, at the start; none per frame or at the landing")
        #expect(page.frame == container.bounds)
    }

    @Test func aGrowingWebKitPageStaysAtTheTopLeftWhileItsPaneGrows() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 320, height: 300), mode: .once)
        let (page, container) = webKitPage(in: pane)

        pane.start(toward: CGSize(width: 640, height: 600))
        container.setFrameSize(NSSize(width: 480, height: 450))
        // Not flipped: the top edge is maxY.
        #expect(page.frame == CGRect(x: 0, y: 450 - 600, width: 640, height: 600))
        container.setFrameSize(NSSize(width: 640, height: 600))
        pane.land()
        #expect(page.sizes.count == 2)
        #expect(page.frame == container.bounds)
    }

    @Test func perFrameResizesTheWebKitPageWithItsPane() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .perFrame)
        let (page, container) = webKitPage(in: pane)

        pane.start(toward: CGSize(width: 320, height: 600))
        for width in [480.0, 320] { container.setFrameSize(NSSize(width: width, height: 600)) }
        pane.land()
        #expect(page.sizes.map(\.width) == [640, 480, 320])
    }

    /// The first frame of a main-thread spring resizes the pane before the spring's start reaches the page:
    /// the page joins at the true rest (the change is the rest less the content's size at that frame), once.
    @Test func aWebKitPageResizedBeforeTheStartJoinsTheSpringAtItsRestOnce() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let (page, container) = webKitPage(in: pane)

        pane.isOnLayoutSpring = true
        pane.rest = CGSize(width: 400, height: 600)
        container.setFrameSize(NSSize(width: 560, height: 600))
        #expect(page.frame.size == CGSize(width: 400, height: 600), "joined at the pane's rest, not at 560 - 240")
        pane.start(toward: CGSize(width: 400, height: 600))
        for width in [480.0, 400] { container.setFrameSize(NSSize(width: width, height: 600)) }
        pane.land()
        #expect(page.sizes.map(\.width) == [640, 400])
        #expect(page.frame == container.bounds)
    }

    @Test func anAttachedInspectorEndsTheHold() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let (page, container) = webKitPage(in: pane)

        pane.start(toward: CGSize(width: 320, height: 600))
        container.addSubview(NSView(frame: .zero))
        #expect(container.springHold == nil, "the inspector owns the web view's frame")
        #expect(page.autoresizingMask == [.width, .height])
    }

    /// A device emulation set during a hold places the page itself, and the landing leaves it there.
    @Test func anEmulationSetDuringTheHoldEndsIt() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let (page, container) = webKitPage(in: pane)

        pane.start(toward: CGSize(width: 320, height: 600))
        container.emulation = BrowserEmulation(width: 200, height: 400, deviceScaleFactor: 2, userAgent: "", chromiumCallsJSON: "")
        #expect(container.springHold == nil, "the emulation owns the web view's frame")
        let emulated = page.frame
        #expect(emulated.size == CGSize(width: 200, height: 400))
        container.setFrameSize(NSSize(width: 320, height: 600))
        pane.land()
        #expect(page.frame.size == CGSize(width: 200, height: 400), "still the device's size after the landing")
    }

    /// A container moved to another pane mid-spring: the old pane's landing never reaches it, so the move ends
    /// the hold and the page fills the container in its new pane.
    @Test func aWebKitPageMovedToAnotherPaneMidSpringFillsItsContainer() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let other = Placement(frame: CGRect(x: 0, y: 0, width: 500, height: 600), mode: .once)
        let (page, container) = webKitPage(in: pane)

        pane.start(toward: CGSize(width: 320, height: 600))
        other.addSubview(container)
        container.setFrameSize(other.bounds.size)
        #expect(container.springHold == nil)
        #expect(page.frame == container.bounds)
        #expect(page.autoresizingMask == [.width, .height])
        #expect(container.layer?.backgroundColor == nil)
    }

    /// The gap beside a held page of a real WebKit tab (its `underPageBackgroundColor` is clear) shows the
    /// document's background the tab read, and nothing for a see-through page.
    @Test func theGapBesideAHeldWebKitTabShowsTheDocumentsBackground() throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        #expect(tab.webView.underPageBackgroundColor.alphaComponent == 0, "the tab's under-page color is no source for the gap")
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 320, height: 300), mode: .once)
        tab.container.frame = pane.bounds
        pane.addSubview(tab.container)
        #expect(tab.container.wantsLayer)
        #expect(tab.container.springPlacement === pane)

        tab.samplePageBackdrop()
        #expect(tab.container.pageBackdrop == nil, "a blank page is see-through: no read, no fill")
        pane.start(toward: CGSize(width: 640, height: 300))
        #expect(tab.container.layer?.backgroundColor == nil)

        // The document's background, as `samplePageBackdrop` sets it once read.
        let documentColor = PageBackground.cgColor(argb: 0xFF10_2030)
        tab.container.pageBackdrop = documentColor
        #expect(tab.container.layer?.backgroundColor == documentColor)
        pane.land()
        #expect(tab.container.layer?.backgroundColor == nil)
    }

    @Test func withoutTheFeatureAWebKitPageResizesWithItsPane() {
        let pane = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 600))
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)
        #expect(container.springPlacement == nil, "no pane with the feature: layouts walk no ancestors")

        container.notifyPaneMotionWillRest(sizeChange: CGSize(width: -320, height: 0))
        container.setFrameSize(NSSize(width: 480, height: 600))
        #expect(page.sizes.map(\.width) == [640, 480])
    }

    // MARK: Chromium

    /// Cmd-D on the main thread's spring frames: the page window follows the pane's frame, stays shown, and
    /// its host view takes one size per Cmd-D, at the start, none per frame or at the landing.
    @Test func aChromiumPageOnAMainThreadSpringResizesOnceAndStaysShown() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let (host, tab) = try Self.shownTab(runtime, in: pane)
        let view = host.hostView
        let sizes = Sizes(view)
        defer { sizes.stop() }

        pane.start(toward: CGSize(width: 320, height: 600))
        #expect(view.childWindowPage.occlusionRects() != [view.bounds])
        for width in [560.0, 480, 400] {
            tab.container.setFrameSize(NSSize(width: width, height: 600))
            #expect(view.frame == CGRect(x: 0, y: 0, width: 320, height: 600), "held at its rest size, at the top-left")
        }
        tab.container.setFrameSize(NSSize(width: 320, height: 600))
        pane.land()
        #expect(view.frame == tab.container.bounds)
        #expect(sizes.sizes == [CGSize(width: 640, height: 600), CGSize(width: 320, height: 600)])
        #expect(!view.isOnPageSpring)
    }

    /// Two Chromium pages a Cmd-D resizes (the new pane's and its neighbour's): each takes its rest size once,
    /// in the start's turn, so a hosted page's resize joins that turn's one fence, and the
    /// landing resizes neither.
    @Test func twoChromiumPagesResizeInTheStartsTurnOnlyAndNotAtTheLanding() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let right = Placement(frame: CGRect(x: 0, y: 0, width: 200, height: 600), mode: .once)
        let (leftHost, leftTab) = try Self.shownTab(runtime, in: left, browser: 10)
        let (rightHost, rightTab) = try Self.shownTab(runtime, in: right, browser: 11)
        let leftSizes = Sizes(leftHost.hostView), rightSizes = Sizes(rightHost.hostView)
        defer { leftSizes.stop(); rightSizes.stop() }

        left.start(toward: CGSize(width: 320, height: 600))
        right.start(toward: CGSize(width: 320, height: 600))
        #expect(leftSizes.sizes.count == 2 && rightSizes.sizes.count == 2, "one resize each in the start's turn")
        for step in 1...3 {
            leftTab.container.setFrameSize(NSSize(width: 640 - 80 * CGFloat(step), height: 600))
            rightTab.container.setFrameSize(NSSize(width: 200 + 40 * CGFloat(step), height: 600))
        }
        left.land()
        right.land()
        #expect(leftSizes.sizes == [CGSize(width: 640, height: 600), CGSize(width: 320, height: 600)])
        #expect(rightSizes.sizes == [CGSize(width: 200, height: 600), CGSize(width: 320, height: 600)])
    }

    /// A render-server spring sets the pane's frame at rest in its first turn: a page window placed from it
    /// would show at the rest place for the whole spring, so it hides while the pane shows the move, also for
    /// a move that keeps the size (a column shifting after a close), and shows again when the move lands.
    @Test func aChromiumPageInItsOwnWindowHidesWhileItsPaneShowsARenderServerMove() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let (host, _) = try Self.shownTab(runtime, in: pane)
        let view = host.hostView
        let sizes = Sizes(view)
        defer { sizes.stop() }
        #expect(view.drawsInChildWindow, "hosting off: the page draws in its own window")
        #expect(view.childWindowPage.occlusionRects() != [view.bounds])

        pane.showsRenderMove = true
        #expect(view.childWindowPage.occlusionRects() == [view.bounds], "its window hides for the move")
        #expect(ChildWindowPageFallback.hidesForSpring(view))
        pane.showsRenderMove = false
        #expect(view.childWindowPage.occlusionRects() != [view.bounds], "it shows again where the pane landed")
        #expect(sizes.sizes == [CGSize(width: 640, height: 600)], "a move resizes nothing")
    }

    /// The main thread took the render spring back (a structural change mid-spring): the page window follows
    /// the pane's frames again, so it shows while the pane is still on its layout spring.
    @Test func aRenderSpringTakenBackShowsThePageWindowBeforeTheLanding() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let (host, _) = try Self.shownTab(runtime, in: pane)
        let view = host.hostView

        pane.showsRenderMove = true
        pane.start(toward: CGSize(width: 320, height: 600))
        #expect(view.childWindowPage.occlusionRects() == [view.bounds])
        pane.showsRenderMove = false
        #expect(pane.isOnLayoutSpring)
        #expect(view.childWindowPage.occlusionRects() != [view.bounds])
        pane.land()
    }

    /// A tab shown while its pane already shows a render-server move missed the start: its page window hides
    /// as it takes the pane's host view.
    @Test func aChromiumTabShownMidRenderMoveHides() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        pane.showsRenderMove = true
        let (host, _) = try Self.shownTab(runtime, in: pane)
        #expect(host.hostView.childWindowPage.occlusionRects() == [host.hostView.bounds])
        pane.showsRenderMove = false
        #expect(host.hostView.childWindowPage.occlusionRects() != [host.hostView.bounds])
    }

    /// A tab's container moved to another pane mid-spring: the move ends the hold, and the page fills its
    /// container at rest there.
    @Test func aChromiumTabMovedToAnotherPaneMidSpringFillsItsContainer() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once)
        let other = Placement(frame: CGRect(x: 0, y: 0, width: 500, height: 600), mode: .once)
        let (host, tab) = try Self.shownTab(runtime, in: pane)

        pane.showsRenderMove = true
        pane.start(toward: CGSize(width: 320, height: 600))
        #expect(tab.container.springHold != nil)
        other.addSubview(tab.container)
        tab.container.setFrameSize(other.bounds.size)
        #expect(tab.container.springHold == nil)
        #expect(host.hostView.frame == tab.container.bounds)
        #expect(!host.hostView.isOnPageSpring)
        #expect(host.hostView.childWindowPage.occlusionRects() != [host.hostView.bounds], "the new pane shows no render move")
        #expect(tab.container.springPlacement === other)
    }

    @Test func withoutTheFeatureAChromiumPageResizesWithItsPane() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 600))
        let (host, tab) = try Self.shownTab(runtime, in: pane)
        #expect(tab.container.springPlacement == nil, "no pane with the feature: layouts walk no ancestors")

        tab.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: -320, height: 0))
        tab.container.notifyPaneRenderMoveChanged(true)
        tab.container.notifyPaneRenderMoveChanged(false)
        tab.container.setFrameSize(NSSize(width: 480, height: 600))
        #expect(host.hostView.frame.size == CGSize(width: 480, height: 600))
        #expect(host.hostView.childWindowPage.occlusionRects() != [host.hostView.bounds])
    }

    // MARK: Fixture

    private static func runtime() throws -> (CEFRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "page-spring-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try QuietShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A Chromium tab shown in `pane`, its browser live in its own window.
    private static func shownTab(_ runtime: CEFRuntime, in pane: NSView, browser: Int32 = 10) throws -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.container.frame = pane.bounds
        tab.container.autoresizingMask = [.width, .height]
        pane.addSubview(tab.container)
        host.add(tab)
        host.present(tab, in: tab.container)
        host.createDeferred()
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
        #expect(tab.browserID == browser)
        #expect(host.hostView.frame == tab.container.bounds)
        return (host, tab)
    }
}

/// A shim whose `cmux_shim_create_window` returns a request id, whose `cmux_shim_fork_api_version` reports 27
/// (layer hosting stays off: `browserResize.layerHosting` defaults off) and whose other functions do nothing.
private nonisolated enum QuietShim {
    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
