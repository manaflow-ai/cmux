import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// Task 220 of plans/cmux-next/chrome-parity/p01-process.md: in host mode the pane's page view
/// tells the Chromium Host what the person sees of its page (`cmux_shim_browser_set_page_visibility`),
/// as Chrome's `WebContentsViewCocoa` tells its WebContents: hidden out of a window, under a hidden
/// view (a workspace switch hides the pane's host view), in a minimized window or a hidden app;
/// occluded in a covered window; else visible.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChromiumHostPageVisibilityTests {
    @Test func workspaceSwitchPostsHiddenAndBack() throws {
        let runtime = try Self.runtime()
        let (host, tab) = try Self.livePane(runtime)
        let window = FakeWindow()
        try Self.watch(host, window)
        VisibilitySpy.reset()

        host.present(tab, in: window.container)
        tab.setContentVisible(false)  // the workspace hides: the host view hides at the end of the turn
        Self.endTurn()
        tab.setContentVisible(true)  // and shows again

        #expect(VisibilitySpy.posts.map(\.visibility) == [Self.visible, Self.hidden, Self.visible])
        #expect(VisibilitySpy.posts.allSatisfy { $0.browser == Self.firstBrowser })
        #expect(tab.contentVisibility.reason != "page_window_missing", "host mode reads the page view, not child windows")
    }

    @Test func occlusionMinimizeAndAppHide() throws {
        let runtime = try Self.runtime()
        let (host, tab) = try Self.livePane(runtime)
        let window = FakeWindow()
        try Self.watch(host, window)
        host.present(tab, in: window.container)
        VisibilitySpy.reset()

        window.change(\.isOccluded, true, NSWindow.didChangeOcclusionStateNotification)
        window.change(\.isOccluded, false, NSWindow.didChangeOcclusionStateNotification)
        window.change(\.isShown, false, NSWindow.didMiniaturizeNotification)
        window.change(\.isShown, true, NSWindow.didDeminiaturizeNotification)
        // The app hides: AppKit orders out its windows, which changes their occlusion.
        window.change(\.isShown, false, NSWindow.didChangeOcclusionStateNotification)
        window.change(\.isShown, true, NSWindow.didChangeOcclusionStateNotification)
        // A notice that changes nothing posts nothing.
        window.change(\.isShown, true, NSWindow.didChangeOcclusionStateNotification)

        #expect(VisibilitySpy.posts.map(\.visibility)
            == [Self.occluded, Self.visible, Self.hidden, Self.visible, Self.hidden, Self.visible])
    }

    @Test func leavingTheWindowHidesThePage() throws {
        let runtime = try Self.runtime()
        let (host, tab) = try Self.livePane(runtime)
        let window = FakeWindow()
        try Self.watch(host, window)
        host.present(tab, in: window.container)
        VisibilitySpy.reset()

        window.container.removeFromSuperview()
        window.window.contentView?.addSubview(window.container)

        #expect(VisibilitySpy.posts.map(\.visibility) == [Self.hidden, Self.visible])
    }

    /// A new Chromium window hears the page view's visibility when it is created, before its page
    /// context is asked for (the host applies it once it detaches the page window); a restarted
    /// host's window, with a new browser id, hears it again.
    @Test func aNewWindowHearsTheVisibility() throws {
        let runtime = try Self.runtime()
        let (host, _) = try Self.livePane(runtime)
        #expect(VisibilitySpy.posts.map(\.visibility) == [Self.hidden], "a page view out of a window")

        host.postPageVisibility(browser: Self.firstBrowser + 1)
        #expect(VisibilitySpy.posts.map(\.browser) == [Self.firstBrowser, Self.firstBrowser + 1])
    }

    /// Docked DevTools is a detached Chromium window of its own: its page view tells the host what
    /// the person sees of it for the DevTools browser, from its open on, as the pane's page view does.
    @Test func dockedDevToolsPostsItsOwnVisibility() throws {
        let runtime = try Self.runtime()
        let (host, tab) = try Self.livePane(runtime)
        let window = FakeWindow()
        try Self.watch(host, window)
        tab.devToolsController.layout = CEFDevToolsLayout()  // docked at the bottom, not the remembered layout
        tab.container.frame = window.container.bounds
        window.container.addSubview(tab.container)
        host.present(tab, in: tab.container)

        tab.devToolsController.perform(.show)
        let devToolsPage = try #require(tab.devToolsController.hostedPage)
        devToolsPage.visibilitySource = window.source
        runtime.handle(.devToolsWillOpen(browser: Self.firstBrowser))
        VisibilitySpy.reset()
        runtime.handle(.devToolsOpened(browser: Self.firstBrowser, devTools: Self.devTools, docked: true))
        tab.setContentVisible(false)  // the workspace hides
        Self.endTurn()
        tab.setContentVisible(true)
        window.change(\.isShown, false, NSWindow.didMiniaturizeNotification)
        window.change(\.isShown, true, NSWindow.didDeminiaturizeNotification)

        let devToolsPosts = VisibilitySpy.posts.filter { $0.browser == Self.devTools }.map(\.visibility)
        #expect(devToolsPosts == [Self.visible, Self.hidden, Self.visible, Self.hidden, Self.visible])
        #expect(VisibilitySpy.posts.first?.browser == Self.devTools, "the open posts the DevTools page's visibility first")

        // Closed, nothing goes for the DevTools browser.
        runtime.handle(.devToolsClosed(browser: Self.firstBrowser, devTools: Self.devTools))
        VisibilitySpy.reset()
        tab.setContentVisible(false)
        Self.endTurn()
        #expect(!VisibilitySpy.posts.contains { $0.browser == Self.devTools })
    }

    /// Task p01-process-084: a pane that starts to show a hosted page while the host is already busy
    /// gets the "Chromium is busy" banner too (a new split, or a tab switch away from the frozen page),
    /// and loses it when it hides.
    @Test func aPaneShownWhileTheHostIsBusyGetsTheBanner() throws {
        let runtime = try Self.runtime()
        let deadline = ChromiumHostHangMonitorTests.FakeDeadline()
        let clock = ChromiumHostHangMonitorTests.FakeClock()
        let monitor = ChromiumHostHangMonitor(deadline: deadline, now: { [clock] in clock.now })
        monitor.onBusyChange = { [weak runtime] busy in runtime?.showHostBusy(busy) }
        runtime.hostStart?.hangMonitor = monitor
        let (first, firstTab) = try Self.livePane(runtime)
        runtime.hosts[first.key] = first  // the routing table showHostBusy walks (livePane makes the pane directly)
        let firstWindow = FakeWindow()
        try Self.watch(first, firstWindow)
        first.present(firstTab, in: firstWindow.container)
        monitor.inputOutstanding()
        clock.advance(ChromiumHostHangMonitor.busyAfter)
        deadline.fire()
        #expect(monitor.isBusy && Self.showsBanner(first))

        let (second, secondTab) = try Self.livePane(runtime, browser: Self.firstBrowser + 2)
        runtime.hosts[second.key] = second
        let secondWindow = FakeWindow()
        try Self.watch(second, secondWindow)
        #expect(!Self.showsBanner(second), "a page out of every window shows no banner")
        second.present(secondTab, in: secondWindow.container)
        #expect(Self.showsBanner(second), "the page shown while the host is busy gets the banner")

        secondWindow.change(\.isShown, false, NSWindow.didMiniaturizeNotification)
        #expect(!Self.showsBanner(second) && Self.showsBanner(first), "hidden: its banner goes, the shown page's stays")
        secondWindow.change(\.isShown, true, NSWindow.didDeminiaturizeNotification)
        #expect(Self.showsBanner(second))
        monitor.inputSettled()
        #expect(!Self.showsBanner(first) && !Self.showsBanner(second), "the host took the input: every banner goes")
    }

    @Test func chromesRule() {
        typealias State = ChromiumHostPageVisibility.WindowState
        #expect(State.visibility(of: nil) == .hidden, "out of every window")
        #expect(State.visibility(of: State(isShown: true, isOccluded: false)) == .visible)
        #expect(State.visibility(of: State(isShown: true, isOccluded: true)) == .occluded)
        #expect(State.visibility(of: State(isShown: false, isOccluded: true)) == .hidden, "minimized, or the app hidden")
        #expect([ChromiumHostPageVisibility.visible, .hidden, .occluded].map(\.rawValue) == [0, 1, 2],
                "cmux_shim_page_visibility_t")
    }

    /// The view's own hidden state, under its window's: a hidden view in a shown window is hidden,
    /// and shows again as it was when the window comes back.
    @Test func aHiddenViewStaysHiddenAcrossItsWindow() {
        let window = FakeWindow()
        let view = ChromiumHostPageView(frame: window.container.bounds, inputTarget: .view,
                                        makeLayerHost: { _ in CALayer() }, windowEventCenter: NotificationCenter())
        view.visibilitySource = window.source
        var seen: [ChromiumHostPageVisibility] = []
        view.onPageVisibility = { seen.append($0) }

        window.container.addSubview(view)
        view.isHidden = true
        window.change(\.isOccluded, true, NSWindow.didChangeOcclusionStateNotification)
        view.isHidden = false
        window.change(\.isOccluded, false, NSWindow.didChangeOcclusionStateNotification)

        #expect(seen == [.visible, .hidden, .occluded, .visible])
    }

    // MARK: Fixtures

    private static let firstBrowser: Int32 = 1
    private static let devTools: Int32 = 2
    private static let visible = ChromiumHostPageVisibility.visible.rawValue
    private static let hidden = ChromiumHostPageVisibility.hidden.rawValue
    private static let occluded = ChromiumHostPageVisibility.occluded.rawValue

    /// A window whose shown and occluded state the test sets, with its own notification center.
    @MainActor final class FakeWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let center = NotificationCenter()
        let events: WindowEvents
        var state = ChromiumHostPageVisibility.WindowState(isShown: true, isOccluded: false)

        init() {
            events = WindowEvents(window: window, center: center)
            window.contentView?.addSubview(container)
        }

        var source: ChromiumHostPageVisibility.Source {
            ChromiumHostPageVisibility.Source(windowState: { [unowned self] _ in state }, events: { [unowned self] _ in events })
        }

        /// Sets `key` and posts `name` from the window, as AppKit does after such a change.
        func change(_ key: WritableKeyPath<ChromiumHostPageVisibility.WindowState, Bool>, _ value: Bool,
                    _ name: Notification.Name) {
            state[keyPath: key] = value
            center.post(name: name, object: window)
        }
    }

    private static func showsBanner(_ host: CEFPaneHost) -> Bool {
        host.hostView.subviews.contains { $0 is ChromiumHostBusyBanner }
    }

    private static func watch(_ host: CEFPaneHost, _ window: FakeWindow) throws {
        let page = try #require(host.hostedPageView)
        page.visibilitySource = window.source
    }

    /// Runs this turn's end-of-turn blocks (the pane host's deferred hide).
    private static func endTurn() {
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
    }

    /// A host-mode runtime that outlives the test (a pane's scheduled work reads it through an unowned reference).
    private static func runtime() throws -> CEFRuntime {
        VisibilitySpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-page-visibility-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(VisibilitySpy.symbol), storage: CEFProfileStorage(root: root))
        let hostStart = CEFHostStart(supervisor: VisibilityNoHost(), clock: ContinuousClock())
        hostStart.mapsClientIDs = true
        runtime.hostStart = hostStart
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    private static func livePane(_ runtime: CEFRuntime, browser: Int32 = firstBrowser) throws -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first { runtime.pendingWindows[$0] === host })
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        #expect(tab.browserID == browser)
        return (host, tab)
    }
}

/// Never attaches: these tests drive panes against the spy shim and never start Chromium.
@MainActor private final class VisibilityNoHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}

/// Stand-in shim functions: `browser_set_page_visibility` records its calls, `fork_api_version`
/// reports 31, every other function does nothing and returns 0.
private nonisolated enum VisibilitySpy {
    nonisolated(unsafe) static var posts: [(browser: Int32, visibility: Int32)] = []

    static func reset() {
        posts = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { 0 }
        let pageVisibility: @convention(c) (Int32, Int32) -> Int32 = { browser, visibility in
            VisibilitySpy.posts.append((browser, visibility))
            return 1
        }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = {
            _, _, _, _, _, _ in 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 31 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_set_page_visibility": unsafeBitCast(pageVisibility, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
