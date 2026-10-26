import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// p03-rendering-036: with the `pageSpringResizeOnce` feature a page in a springing pane resizes once, at the
/// spring's start, to the size its pane rests at, and not again at the landing (F12: both engines); a hosted
/// Chromium page's resize joins the window's one fence of the turn; a page in its own window hides for the
/// spring instead of showing at the pane's rest place.
@MainActor @Suite(.serialized) struct PageSpringResizeTests {
    /// A pane host as the layout makes it, reduced to what pages read: its spring flag, its rest size change
    /// and the window's page resizing.
    final class Placement: NSView, RestingPlacement {
        var restOffset: CGVector = .zero
        var isOnLayoutSpring = false
        var restContentSizeChange: CGSize?
        var isOnRenderSpring = false
        let pageResizing: PageSpringResizing?

        init(frame: CGRect, mode: SpringPageResize, fence: ResizeFenceTurn) {
            pageResizing = PageSpringResizing(mode: { mode }, fence: fence)
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// A spring that will rest `change` larger starts.
        func start(_ change: CGSize, in content: NSView) {
            isOnLayoutSpring = true
            restContentSizeChange = change
            content.notifyPaneMotionWillRest(sizeChange: change)
        }

        /// The spring lands.
        func land(_ content: NSView) {
            isOnLayoutSpring = false
            restContentSizeChange = nil
            content.notifyPaneMotionSettled()
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

    /// A turn's commit the test runs itself.
    final class Commits {
        var blocks: [@MainActor () -> Void] = []
        func commit() {
            let due = blocks
            blocks = []
            for block in due { block() }
        }
    }

    let commits = Commits()
    /// Layer hosting's end-of-turn requests, run by the test.
    let hostingTurn = HostingTurn()

    final class HostingTurn {
        private var blocks: [@MainActor @Sendable () -> Void] = []
        func add(_ block: @escaping @MainActor @Sendable () -> Void) { blocks.append(block) }
        func end() {
            let due = blocks
            blocks = []
            for block in due { block() }
        }
    }

    /// Layer hosting of a page window over a new view (`views` keeps the view: hosting holds it weakly).
    func makeHosting(enabled: Bool, views: inout [NSView]) -> CEFLayerHosting {
        let turn = hostingTurn
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) })
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        views.append(view)
        hosting.view = view
        return hosting
    }

    func fence(opened: @escaping () -> UInt32? = { nil }, released: @escaping (UInt32) -> Void = { _ in }) -> ResizeFenceTurn {
        let commits = commits
        return ResizeFenceTurn(port: ResizeFenceTurn.Port(open: opened, release: released), afterCommit: { commits.blocks.append($0) })
    }

    // MARK: WebKit

    @Test func aWebKitPageResizesOnceAtTheSpringsStartAndNotAtItsLanding() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once, fence: fence())
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)
        #expect(page.sizes == [CGSize(width: 640, height: 600)])

        // Cmd-D: the pane will rest at half its width.
        pane.start(CGSize(width: -320, height: 0), in: container)
        #expect(page.sizes.last == CGSize(width: 320, height: 600), "the page takes its rest size at the start")
        #expect(page.frame.origin == CGPoint(x: 0, y: 0), "held at the top-left")
        // The main thread's spring frames shrink the pane toward its rest.
        for width in [560.0, 480, 400, 320] { container.setFrameSize(NSSize(width: width, height: 600)) }
        pane.land(container)
        #expect(page.sizes == [CGSize(width: 640, height: 600), CGSize(width: 320, height: 600)],
                "one resize per Cmd-D, at the start; none per frame or at the landing")
        #expect(page.frame == container.bounds)
    }

    @Test func aGrowingWebKitPageStaysAtTheTopLeftWhileItsPaneGrows() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 320, height: 300), mode: .once, fence: fence())
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)

        pane.start(CGSize(width: 320, height: 300), in: container)
        container.setFrameSize(NSSize(width: 480, height: 450))
        // Not flipped: the top edge is maxY.
        #expect(page.frame == CGRect(x: 0, y: 450 - 600, width: 640, height: 600))
        container.setFrameSize(NSSize(width: 640, height: 600))
        pane.land(container)
        #expect(page.sizes.count == 2)
        #expect(page.frame == container.bounds)
    }

    @Test func perFrameResizesTheWebKitPageWithItsPane() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .perFrame, fence: fence())
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)

        pane.start(CGSize(width: -320, height: 0), in: container)
        for width in [480.0, 320] { container.setFrameSize(NSSize(width: width, height: 600)) }
        pane.land(container)
        #expect(page.sizes.map(\.width) == [640, 480, 320])
    }

    /// The first frame of a main-thread spring resizes the pane before the spring's start reaches the page.
    @Test func aWebKitPageResizedBeforeTheStartJoinsTheSpringOnce() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once, fence: fence())
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)

        pane.isOnLayoutSpring = true
        pane.restContentSizeChange = CGSize(width: -240, height: 0)
        container.setFrameSize(NSSize(width: 560, height: 600))
        pane.start(CGSize(width: -240, height: 0), in: container)
        container.setFrameSize(NSSize(width: 320, height: 600))
        pane.land(container)
        #expect(page.sizes.map(\.width) == [640, 320])
    }

    @Test func anAttachedInspectorEndsTheHold() {
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once, fence: fence())
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)

        pane.start(CGSize(width: -320, height: 0), in: container)
        container.addSubview(NSView(frame: .zero))
        #expect(container.springHold == nil, "the inspector owns the web view's frame")
        #expect(page.autoresizingMask == [.width, .height])
    }

    @Test func withoutTheFeatureAWebKitPageResizesWithItsPane() {
        let pane = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 600))
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        container.frame = pane.bounds
        pane.addSubview(container)

        container.notifyPaneMotionWillRest(sizeChange: CGSize(width: -320, height: 0))
        container.setFrameSize(NSSize(width: 480, height: 600))
        #expect(page.sizes.map(\.width) == [640, 480])
    }

    // MARK: Chromium

    /// A render-server spring sets the pane's frame at rest in its first turn: a page window placed from it
    /// would show at the rest place for the whole spring, so it hides until the landing.
    @Test func aChromiumPageInItsOwnWindowResizesOnceAndHidesUntilARenderServerSpringLands() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        var opened = 0
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once,
                             fence: fence(opened: { opened += 1; return 5 }))
        let (host, tab) = try Self.shownTab(runtime, in: pane)
        let view = host.hostView
        #expect(view.drawsInChildWindow, "hosting off: the page draws in its own window")
        #expect(view.allOcclusionRects != [view.bounds])

        pane.isOnRenderSpring = true
        pane.start(CGSize(width: -320, height: 0), in: tab.container)
        #expect(view.frame == CGRect(x: 0, y: 0, width: 640 - 320, height: 600), "the page takes its rest size at the start")
        #expect(view.allOcclusionRects == [view.bounds], "its window hides for the spring")
        tab.container.setFrameSize(NSSize(width: 320, height: 600))
        pane.isOnRenderSpring = false
        pane.land(tab.container)
        #expect(view.frame == CGRect(x: 0, y: 0, width: 320, height: 600), "no resize at the landing")
        #expect(view.allOcclusionRects != [view.bounds], "it shows again at the landing")
        #expect(opened == 0, "a page in its own window opens no fence")
    }

    /// On the main thread's spring frames the page window follows the pane's frame: it stays shown, held at
    /// its rest size, and resizes once.
    @Test func aChromiumPageOnAMainThreadSpringStaysShownAndResizesOnce() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Placement(frame: CGRect(x: 0, y: 0, width: 640, height: 600), mode: .once, fence: fence())
        let (host, tab) = try Self.shownTab(runtime, in: pane)
        let view = host.hostView

        pane.start(CGSize(width: -320, height: 0), in: tab.container)
        #expect(view.allOcclusionRects != [view.bounds])
        for width in [560.0, 480, 400] {
            tab.container.setFrameSize(NSSize(width: width, height: 600))
            #expect(view.frame == CGRect(x: 0, y: 0, width: 320, height: 600), "held at its rest size, at the top-left")
        }
        tab.container.setFrameSize(NSSize(width: 320, height: 600))
        pane.land(tab.container)
        #expect(view.frame == tab.container.bounds)
        #expect(view.spring == nil)
    }

    @Test func withoutTheFeatureAChromiumPageResizesWithItsPane() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 600))
        let (host, tab) = try Self.shownTab(runtime, in: pane)

        tab.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: -320, height: 0))
        tab.container.setFrameSize(NSSize(width: 480, height: 600))
        #expect(host.hostView.frame.size == CGSize(width: 480, height: 600))
        #expect(host.hostView.allOcclusionRects != [host.hostView.bounds])
    }

    /// Every hosted page a spring's start resizes joins one fence, released after the turn's commit; the next
    /// turn opens its own.
    @Test func hostedPagesResizedInOneTurnShareOneFence() {
        var opened: [UInt32] = [], released: [UInt32] = []
        var next: UInt32 = 40
        let turn = fence(opened: { next += 1; opened.append(next); return next }, released: { released.append($0) })
        var joins: [(browser: Int32, fence: UInt32, frames: UInt32)] = []
        var views: [NSView] = []
        let left = makeHosting(enabled: true, views: &views), right = makeHosting(enabled: true, views: &views)
        for (hosting, browser) in [(left, Int32(3)), (right, 4)] {
            hosting.pageWindowCreated(browser: browser, fork: CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 },
                                                                                 setResizeFence: { browser, fence, frames in
                                                                                     joins.append((browser, fence, frames))
                                                                                     return true
                                                                                 }))
        }
        hostingTurn.end()
        #expect(left.page != nil && right.page != nil)

        left.pageResized(in: turn)
        right.pageResized(in: turn)
        #expect(opened == [41], "one fence per spring start")
        #expect(joins.map(\.browser) == [3, 4])
        #expect(joins.allSatisfy { $0.fence == 41 && $0.frames == 2 })
        #expect(released.isEmpty, "held until the turn commits")
        commits.commit()
        #expect(released == [41])

        left.pageResized(in: turn)
        #expect(opened == [41, 42], "the next turn opens its own")
        #expect(left.fencedResizes == 2)
        #expect(views.count == 2)
    }

    @Test func aPageInItsOwnWindowOrWithoutTheForkAPIJoinsNoFence() {
        var opened = 0
        let turn = fence(opened: { opened += 1; return 9 })
        var views: [NSView] = []
        let offHosting = makeHosting(enabled: false, views: &views)
        offHosting.pageWindowCreated(browser: 3, fork: CEFLayerHosting.Fork(setLayerHosting: { _, _ in 0 }, setResizeFence: { _, _, _ in true }))
        let oldFork = makeHosting(enabled: true, views: &views)
        oldFork.pageWindowCreated(browser: 4, fork: CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 }))
        hostingTurn.end()
        #expect(offHosting.page == nil, "hosting off: the page draws in its own window")
        #expect(oldFork.page != nil, "the old fork's page is hosted")

        offHosting.pageResized(in: turn)
        oldFork.pageResized(in: turn)
        #expect(opened == 0)
        #expect(views.count == 2)
    }

    // MARK: Fixture

    private static func runtime() throws -> (CEFRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "page-spring-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try QuietShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A Chromium tab shown in `pane`, its browser (10) live in its own window.
    private static func shownTab(_ runtime: CEFRuntime, in pane: NSView) throws -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.container.frame = pane.bounds
        tab.container.autoresizingMask = [.width, .height]
        pane.addSubview(tab.container)
        host.add(tab)
        host.present(tab, in: tab.container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        #expect(tab.browserID == 10)
        #expect(host.hostView.frame == tab.container.bounds)
        return (host, tab)
    }
}

/// A shim whose `cmux_shim_create_window` returns a request id and every other function does nothing.
private nonisolated enum QuietShim {
    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
                : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
