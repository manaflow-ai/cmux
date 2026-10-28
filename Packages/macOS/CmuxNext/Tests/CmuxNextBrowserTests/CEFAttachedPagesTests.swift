import AppKit
@testable import CmuxNextBrowser
import Testing

/// A pane's tabs on Chromium's own attached view (Track B), through the fork seam: the fake
/// attach call adds a stand-in for the tab's `WebContentsViewCocoa` below the host view's subviews and answers
/// 1 or 0, as the fork's `cmux_browser_attach_view` does. No Chromium.
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

    /// The fork: attach and layer hosting calls, and the browsers it refuses to attach (always, or once).
    final class FakeFork {
        private(set) var attaches: [Int32] = []
        private(set) var hostingCalls: [(browser: Int32, enabled: Bool)] = []
        var refuses: Set<Int32> = []
        var refusesOnce: Set<Int32> = []

        /// `widgets`: the kinds of page window the fork attaches (``CEFLayerHosting/Fork/attachedWidgets``).
        func fork(attaching: Bool = true, widgets: Set<CEFLayerHosting.Widget> = [.page]) -> CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { [self] browser, enabled in
                hostingCalls.append((browser, enabled))
                return enabled ? 7 : 0
            }, attachView: attaching ? { [self] browser, parent in
                attaches.append(browser)
                guard !refuses.contains(browser), refusesOnce.remove(browser) == nil else { return false }
                parent.addSubview(FakeChromiumView(browser: browser), positioned: .below, relativeTo: nil)
                return true
            } : nil, attachedWidgets: widgets)
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
        return CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), layerHosting: hosting)
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
        // The fork refused 4: it takes the page window's hosting, the context-id fallback, and one retry waits.
        #expect(fake.attaches == [3, 4])
        #expect(hosting.attachedPages.retryArmed == [4])
        #expect(fake.hostingCalls.map(\.enabled) == [true])
        #expect(hosting.page != nil)
        #expect(try #require(attached(host, 3)).isHidden)
        // Back to the attached tab: hosting goes.
        hosting.pageShown(browser: 3)
        #expect(fake.hostingCalls.map(\.enabled) == [true, false])
        #expect(hosting.page == nil)
        // The next show of 4 is its one retry; the second refusal is final and 4 takes hosting again.
        hosting.pageShown(browser: 4)
        turn.end()
        #expect(fake.attaches == [3, 4, 4])
        #expect(hosting.attachedPages.refused == [4] && hosting.attachedPages.retryArmed.isEmpty)
        #expect(fake.hostingCalls.map(\.enabled) == [true, false, true])
        // Never asked again: not on a show, not on a tracker read.
        hosting.pageShown(browser: 3)
        hosting.pageShown(browser: 4)
        hosting.trackerDidRead()
        turn.end()
        #expect(fake.attaches == [3, 4, 4])
    }

    @Test func aRefusalAtCreationRetriesOnTheTrackersNextRead() throws {
        let host = makeHostView()
        let hosting = host.layerHosting
        // Chromium had not put the WebContents in its page window yet at the end of the creation turn.
        fake.refusesOnce = [3]
        hosting.pageWindowCreated(browser: 3, fork: fake.fork())
        hosting.pageShown(browser: 3)
        turn.end()
        #expect(fake.attaches == [3])
        #expect(attached(host, 3) == nil)
        #expect(hosting.page != nil, "the refused tab takes the hosting fallback until its retry")
        // The tracker read the host view: the page window is there, so the retry attaches.
        hosting.trackerDidRead()
        hosting.trackerDidRead()
        turn.end()
        #expect(fake.attaches == [3, 3], "one retry, however many tracker reads: \(fake.attaches)")
        let page = try #require(attached(host, 3))
        #expect(!page.isHidden)
        #expect(hosting.page == nil, "the attached tab kept the hosting fallback")
        #expect(fake.hostingCalls.map(\.enabled) == [true, false])
        #expect(hosting.attachedPages.retryArmed.isEmpty && hosting.attachedPages.refused.isEmpty)
    }

    @Test func aTabSwitchHandsThePageFocusToTheShownTab() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let host = makeHostView()
        window.contentView?.addSubview(host)
        let hosting = host.layerHosting
        fake.refuses = [5]
        hosting.pageWindowCreated(browser: 3, fork: fake.fork())
        for browser: Int32 in [4, 3] {
            hosting.pageShown(browser: browser)
            turn.end()
        }
        let three = try #require(attached(host, 3))
        let four = try #require(attached(host, 4))
        window.makeFirstResponder(three)
        hosting.pageShown(browser: 4)
        #expect(window.firstResponder === four, "first responder after a tab switch: \(String(describing: window.firstResponder))")
        #expect(three.isHidden && !four.isHidden)
        // A tab with no attached view: the window takes the focus, not some other key view.
        hosting.pageShown(browser: 5)
        #expect(window.firstResponder === window, "first responder after a switch to an unattached tab: \(String(describing: window.firstResponder))")
        #expect(four.isHidden)
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

    @Test func aDevToolsOrPopupWindowDoesNotAttachOnAForkThatAttachesOnlyAPage() {
        for widget in [CEFLayerHosting.Widget.devTools, .popup, .popupWindow] {
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

    @Test func theShimsAttachCallNeedsTheFeatureForkAPI36AndAnInProcessShim() throws {
        AttachSpy.calls = []
        let shim = try CEFShimLibrary.resolving(AttachSpy.symbol)
        let policy = CEFLayerHosting.Policy(attachesViews: true)
        let on = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: CEFLayerHosting.attachViewForkAPI, policy: policy))
        let parent = NSView()
        let attach = try #require(on.attachView)
        #expect(attach(9, parent), "the shim's 1 is an attach")
        #expect(!attach(AttachSpy.refusedBrowser, parent), "the shim's 0 is a refusal")
        let pointer = Unmanaged.passUnretained(parent).toOpaque()
        #expect(AttachSpy.calls.map(\.browser) == [9, AttachSpy.refusedBrowser])
        #expect(AttachSpy.calls.allSatisfy { $0.parent == pointer })
        // Fork API 35 (056's widget hosting) and earlier: no fork binding, so the shim refuses every page.
        let older = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: CEFLayerHosting.attachViewForkAPI - 1, policy: policy))
        #expect(older.attachView == nil)
        let off = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: CEFLayerHosting.attachViewForkAPI,
                                                    policy: CEFLayerHosting.Policy(attachesViews: false)))
        #expect(off.attachView == nil)
        // Host mode: no view pointer crosses the process.
        let remote = try CEFShimLibrary.resolving(AttachSpy.symbol, hostExports: ["cmux_shim_browser_attach_view"])
        #expect(remote.browserAttachView == nil)
        let withoutExport = try CEFShimLibrary.resolving { $0 == "cmux_shim_browser_attach_view" ? nil : AttachSpy.symbol($0) }
        #expect(withoutExport.browserAttachView == nil)
    }
}

/// A shim whose attach call records the browser and parent pointer it got and answers 1, or 0 for
/// ``refusedBrowser``, as `cmux_shim_browser_attach_view` does.
private nonisolated enum AttachSpy {
    static let refusedBrowser: Int32 = 8
    nonisolated(unsafe) static var calls: [(browser: Int32, parent: UnsafeMutableRawPointer?)] = []

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let attach: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32 = { browser, parent in
            AttachSpy.calls.append((browser, parent))
            return browser == AttachSpy.refusedBrowser ? 0 : 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_attach_view": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
