import AppKit
@testable import CmuxNextBrowser
import Testing

/// A pane's tabs on Chromium's own attached view (p03-rendering-045, Track B), through the fork seam: the fake
/// attach call adds a stand-in for `RenderWidgetHostViewCocoa` to the host view, as the fork's
/// `cmux_browser_attach_view` (p03-rendering-044) does. No Chromium.
@MainActor
@Suite struct CEFAttachedPagesTests {
    /// Chromium's page view: it takes the first click and makes itself first responder on a mouse down, as
    /// `RenderWidgetHostViewCocoa` does (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`).
    final class FakeChromiumView: NSView {
        let browser: Int32
        init(browser: Int32) {
            self.browser = browser
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    }

    /// The fork: attach and layer hosting calls, and the browsers it refuses to attach.
    final class FakeFork {
        private(set) var attaches: [Int32] = []
        private(set) var hostingCalls: [(browser: Int32, enabled: Bool)] = []
        var refuses: Set<Int32> = []

        func fork(attaching: Bool = true) -> CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { [self] browser, enabled in
                hostingCalls.append((browser, enabled))
                return enabled ? 7 : 0
            }, attachView: attaching ? { [self] browser, parent in
                attaches.append(browser)
                guard !refuses.contains(browser) else { return nil }
                let view = FakeChromiumView(browser: browser)
                parent.addSubview(view, positioned: .below, relativeTo: nil)
                return view
            } : nil)
        }
    }

    /// Blocks waiting for the end of the run-loop turn.
    final class Turn {
        private var blocks: [@MainActor @Sendable () -> Void] = []
        func add(_ block: @escaping @MainActor @Sendable () -> Void) { blocks.append(block) }
        func end() {
            let due = blocks
            blocks = []
            for block in due { block() }
        }
    }

    let fake = FakeFork()
    let turn = Turn()

    /// A host view whose hosting ends its turns on ``turn``; hosting itself is on (the fallback of a refused tab).
    func makeHostView() -> CEFHostView {
        let turn = turn
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) })
        return CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), pageUpdateCenter: NotificationCenter(), layerHosting: hosting)
    }

    func attached(_ host: CEFHostView, _ browser: Int32) -> FakeChromiumView? {
        host.layerHosting.attachedPages.view(of: browser) as? FakeChromiumView
    }

    @Test func eachBrowserAttachesOnceAndATabSwitchMakesNoForkCall() throws {
        let host = makeHostView()
        let hosting = host.layerHosting
        hosting.pageWindowCreated(browser: 3, fork: fake.fork())
        hosting.pageShown(browser: 3)
        // Inside Chromium's creation stack the page is not in its window yet.
        #expect(fake.attaches.isEmpty)
        turn.end()
        #expect(fake.attaches == [3])
        hosting.pageShown(browser: 4)
        turn.end()
        #expect(fake.attaches == [3, 4])
        for browser: Int32 in [3, 4, 3, 4, 4, 3] {
            hosting.pageShown(browser: browser)
            turn.end()
        }
        #expect(fake.attaches == [3, 4], "a tab switch attached again: \(fake.attaches)")
        #expect(hosting.attachedPages.attachCalls == 2)
        #expect(fake.hostingCalls.isEmpty, "an attached page asked for layer hosting of its page window")
        #expect(hosting.page == nil)
        let three = try #require(attached(host, 3))
        let four = try #require(attached(host, 4))
        #expect(!three.isHidden && four.isHidden, "only the shown tab's view shows")
    }

    @Test func anAttachedPageNeedsNoChildWindowPath() throws {
        let host = makeHostView()
        #expect(host.drawsInChildWindow)
        host.layerHosting.pageWindowCreated(browser: 3, fork: fake.fork())
        host.layerHosting.pageShown(browser: 3)
        turn.end()
        #expect(!host.drawsInChildWindow, "the layout still moves the pane as a child-window page")
        #expect(ChildWindowPageFallback.cutouts(around: host).isEmpty)
        #expect(host.layerHosting.drawsWithViews)
    }

    @Test func layoutSizesTheShownViewToTheHostView() throws {
        let host = makeHostView()
        host.layerHosting.pageWindowCreated(browser: 3, fork: fake.fork())
        host.layerHosting.pageShown(browser: 3)
        turn.end()
        let page = try #require(attached(host, 3))
        #expect(page.frame == host.bounds)
        host.setFrameSize(NSSize(width: 640, height: 480))
        host.layout()
        #expect(page.frame == host.bounds, "the attached view is \(page.frame), the host \(host.bounds)")
        #expect(host.subviews.first === page, "a find bar or prompt bar must stay above the page")
    }

    @Test func aClickOnThePageMakesChromiumsViewTheFirstResponder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let host = makeHostView()
        window.contentView?.addSubview(host)
        host.layerHosting.pageWindowCreated(browser: 3, fork: fake.fork())
        host.layerHosting.pageShown(browser: 3)
        turn.end()
        let page = try #require(attached(host, 3))
        let point = host.convert(CGPoint(x: 200, y: 150), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
        }
        #expect(window.firstResponder === page, "first responder after a page click: \(String(describing: window.firstResponder))")
    }

    @Test func aRefusedTabKeepsLayerHostingAndAnAttachedTabDropsIt() throws {
        let host = makeHostView()
        let hosting = host.layerHosting
        fake.refuses = [4]
        hosting.pageWindowCreated(browser: 3, fork: fake.fork())
        hosting.pageShown(browser: 3)
        turn.end()
        hosting.pageShown(browser: 4)
        turn.end()
        // The fork refused 4: it takes the page window's hosting, the context-id fallback.
        #expect(fake.attaches == [3, 4])
        #expect(fake.hostingCalls.map(\.enabled) == [true])
        #expect(hosting.page != nil)
        #expect(try #require(attached(host, 3)).isHidden)
        // Back to the attached tab: hosting goes, and 4 is never asked to attach again.
        hosting.pageShown(browser: 3)
        #expect(fake.hostingCalls.map(\.enabled) == [true, false])
        #expect(hosting.page == nil)
        hosting.pageShown(browser: 4)
        turn.end()
        #expect(fake.attaches == [3, 4])
    }

    @Test func aClosedTabsViewIsForgottenAndStopClearsAll() throws {
        let host = makeHostView()
        let hosting = host.layerHosting
        hosting.pageWindowCreated(browser: 3, fork: fake.fork())
        hosting.pageShown(browser: 3)
        turn.end()
        hosting.pageShown(browser: 4)
        turn.end()
        hosting.windowBrowsersChanged([4])
        #expect(hosting.attachedPages.view(of: 3) == nil)
        #expect(hosting.attachedPages.shownView != nil)
        hosting.stop()
        #expect(hosting.attachedPages.shownView == nil)
        #expect(host.drawsInChildWindow)
    }

    /// The fallback is unchanged without the attach call (feature off, an older fork, host mode).
    @Test func withoutTheAttachCallThePageWindowIsHostedAsBefore() {
        let host = makeHostView()
        host.layerHosting.pageWindowCreated(browser: 3, fork: fake.fork(attaching: false))
        turn.end()
        #expect(fake.attaches.isEmpty)
        #expect(fake.hostingCalls.map(\.browser) == [3])
        #expect(host.layerHosting.page != nil)
    }

    @Test func aDevToolsOrPopupWindowNeverAttaches() {
        for widget in [CEFLayerHosting.Widget.devTools, .popup] {
            let host = makeHostView()
            host.layerHosting.widget = widget
            host.layerHosting.pageWindowCreated(browser: 5, fork: fake.fork())
            host.layerHosting.pageShown(browser: 5)
            turn.end()
            #expect(host.layerHosting.attachedPages.attachCalls == 0, "\(widget) attached")
        }
        #expect(fake.attaches.isEmpty)
    }

    // MARK: The shim

    @Test func theShimsAttachCallNeedsTheFeatureAndAnInProcessShim() throws {
        AttachSpy.browsers = []
        let shim = try CEFShimLibrary.resolving(AttachSpy.symbol)
        let on = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: 32, policy: CEFLayerHosting.Policy(attachesViews: true)))
        let parent = NSView()
        let attach = try #require(on.attachView)
        #expect(attach(9, parent) === parent)
        #expect(AttachSpy.browsers == [9])
        let off = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: 32, policy: CEFLayerHosting.Policy(attachesViews: false)))
        #expect(off.attachView == nil)
        // Host mode: no view pointer crosses the process.
        let remote = try CEFShimLibrary.resolving(AttachSpy.symbol, hostExports: ["cmux_shim_browser_attach_view"])
        #expect(remote.browserAttachView == nil)
        let older = try CEFShimLibrary.resolving { $0 == "cmux_shim_browser_attach_view" ? nil : AttachSpy.symbol($0) }
        #expect(older.browserAttachView == nil)
    }
}

/// A shim whose attach call hands back the parent view it got, so the pointer round trip shows.
private nonisolated enum AttachSpy {
    nonisolated(unsafe) static var browsers: [Int32] = []

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let attach: @convention(c) (Int32, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { browser, parent in
            AttachSpy.browsers.append(browser)
            return parent
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_attach_view": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
