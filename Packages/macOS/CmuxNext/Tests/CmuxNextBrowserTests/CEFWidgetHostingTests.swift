import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Per-widget hosting and attach: every kind of page window a cmux view shows, not only a
/// pane's page, hosts (Track A) or attaches (Track B) where the fork does it for that kind
/// (`Fork.hostedWidgets`, `Fork.attachedWidgets`): an embedded DevTools (docked, and in cmux's DevTools window
/// after a dock move), a `window.open` popup host's window and an extension's attached popup window
/// (`chrome.windows.create` type popup). Each kind is driven through the fork seam, without Chromium, and
/// `debug.cef` `tracker.hosted_pages` counts each kind's view. No fork API hosts or attaches the other kinds yet,
/// so the runtime's own fork keeps them in their own window; the owners' wiring is checked through it.
@MainActor
@Suite(.serialized) struct CEFWidgetHostingTests {
    private static let allKinds = Set(CEFLayerHosting.Widget.allCases)
    private static let page: Int32 = 1
    private static let devTools: Int32 = 2

    // MARK: The fork's kinds

    @Test func theShimsForkHostsAndAttachesOnlyATabsPage() throws {
        let shim = try CEFShimLibrary.resolving(WidgetSpy.symbol)
        let policy = CEFLayerHosting.Policy(trackA: .required, attachesViews: true)
        for api: Int32 in [CEFLayerHosting.forkAPI, CEFLayerHosting.attachViewForkAPI, CEFLayerHosting.embedderVisibilityForkAPI, 40] {
            let fork = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: api, policy: policy))
            #expect(fork.hostedWidgets == [.page], "fork API \(api)")
            #expect(fork.attachedWidgets == [.page], "fork API \(api)")
        }
    }

    @Test func eachKindHostsWithAForkThatHostsItAndEveryTrackACall() {
        let fake = CEFLayerHostingTests.FakeFork()
        for widget in CEFLayerHosting.Widget.allCases {
            let host = { (widgets: Set<CEFLayerHosting.Widget>, trackA: CEFLayerHosting.TrackA?) in
                CEFLayerHosting.hosting(override: false, fork: Self.fork(fake, widgets: widgets, trackA: trackA), widget: widget)
            }
            #expect(host(Self.allKinds, .required) == .hosted, "\(widget)")
            #expect(host([widget], .required) == .hosted, "\(widget)")
            #expect(host(Self.allKinds, [.resizeFence]) == .missingTrackA, "\(widget)")
            #expect(host(Self.allKinds, nil) == .off, "\(widget)")
            #expect(host([.page], .required) == (widget == .page ? .hosted : .widgetFallback), "\(widget)")
        }
    }

    @Test func eachKindsHostedViewCountsInTheTrackerByKind() throws {
        let window = Self.window()
        for widget in CEFLayerHosting.Widget.allCases {
            let fake = CEFLayerHostingTests.FakeFork()
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView?.addSubview(view)
            let hosting = Self.hosting(schedule: { $0() })
            hosting.view = view
            hosting.widget = widget
            let before = CEFHostView.trackerStats

            hosting.pageWindowCreated(browser: 3, fork: Self.fork(fake, widgets: [widget], trackA: .required))

            #expect(fake.calls.map(\.enabled) == [true], "\(widget)")
            let page = try #require(hosting.page)
            #expect(page.contextID == 7)
            #expect(page.hostedWidget == widget.name)
            #expect(CEFHostView.trackerStats.hostedPages == before.hostedPages + 1, "\(widget)")
            #expect(CEFHostView.trackerStats.hostedPagesByWidget[widget.name, default: 0]
                == before.hostedPagesByWidget[widget.name, default: 0] + 1, "\(widget)")
            #expect(CEFHostView.trackerStats.hostingWidgetFallbacks == before.hostingWidgetFallbacks)

            hosting.stop()
            #expect(fake.calls.last.map { [$0.browser == 3, $0.enabled] } == [true, false], "\(widget)")
            #expect(CEFHostView.trackerStats.hostedPages == before.hostedPages, "\(widget)")
            #expect(CEFHostView.trackerStats.hostedPagesByWidget == before.hostedPagesByWidget, "\(widget)")
            view.removeFromSuperview()
        }
    }

    /// A DevTools frontend's hosted view moves with its host view into cmux's DevTools window (`undockViews`):
    /// the page window, its context and its count go along with no fork call.
    @Test func aHostedDevToolsKeepsItsContextAcrossADockMove() throws {
        let fake = CEFLayerHostingTests.FakeFork()
        let hostView = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                   layerHosting: Self.hosting(schedule: { $0() }))
        hostView.layerHosting.widget = .devTools
        let paneWindow = Self.window()
        paneWindow.contentView?.addSubview(hostView)
        let before = CEFHostView.trackerStats

        hostView.layerHosting.pageWindowCreated(browser: Self.devTools, fork: Self.fork(fake, widgets: [.devTools], trackA: .required))
        #expect(fake.calls.map(\.enabled) == [true])

        let devToolsWindow = Self.window()
        devToolsWindow.contentView?.addSubview(hostView)
        #expect(fake.calls.count == 1, "a dock move asked the fork again")
        #expect(hostView.layerHosting.page?.contextID == 7)
        #expect(CEFHostView.trackerStats.hostedPagesByWidget["devtools", default: 0]
            == before.hostedPagesByWidget["devtools", default: 0] + 1)

        hostView.layerHosting.stop()
        #expect(CEFHostView.trackerStats.hostedPagesByWidget == before.hostedPagesByWidget)
    }

    // MARK: Track B

    /// Each kind attaches Chromium's view where the fork attaches that kind. A DevTools frontend's and an
    /// attached popup window's one browser shows from the page window's creation; a pane's and a popup host's
    /// tab shows when the host presents it.
    @Test func eachKindAttachesWithAForkThatAttachesIt() throws {
        for widget in CEFLayerHosting.Widget.allCases {
            let fake = CEFAttachedPagesTests.FakeFork()
            let turn = CEFLayerHostingTests.Turn()
            let hostView = Self.hostView(turn)
            hostView.layerHosting.widget = widget
            #expect(CEFLayerHosting.attaches(fork: fake.fork(widgets: [widget]), widget: widget), "\(widget)")

            hostView.layerHosting.pageWindowCreated(browser: 5, fork: fake.fork(widgets: [widget]))
            if !widget.showsOneBrowser { hostView.layerHosting.pageShown(browser: 5) }
            #expect(fake.attaches.isEmpty, "\(widget) attached inside Chromium's creation stack")
            turn.end()

            #expect(fake.attaches == [5], "\(widget)")
            let view = try #require(hostView.layerHosting.attachedPages.view(of: 5), "\(widget)")
            #expect(!view.isHidden, "\(widget)'s attached view stays hidden")
            #expect(view.frame == hostView.bounds, "\(widget)")
            #expect(hostView.layerHosting.drawsWithViews, "\(widget)")
            #expect(!hostView.drawsInChildWindow, "\(widget)")
            #expect(fake.hostingCalls.isEmpty, "an attached \(widget) asked for layer hosting of its page window")
        }
    }

    /// A kind the fork does not attach takes the hosting fallback (or its own window), never an attach call.
    @Test func aKindTheForkDoesNotAttachHostsInstead() {
        for widget in [CEFLayerHosting.Widget.devTools, .popup, .popupWindow] {
            let fake = CEFAttachedPagesTests.FakeFork()
            let turn = CEFLayerHostingTests.Turn()
            let hostView = Self.hostView(turn)
            hostView.layerHosting.widget = widget
            hostView.layerHosting.pageWindowCreated(browser: 5, fork: fake.fork(widgets: Self.allKinds.subtracting([widget])))
            turn.end()
            #expect(fake.attaches.isEmpty, "\(widget)")
            #expect(fake.hostingCalls.map(\.browser) == [5], "\(widget)")
        }
    }

    /// An attached DevTools view is a subview of its host view: a dock move takes it along with no attach call,
    /// and a close (`stop`) forgets it.
    @Test func anAttachedDevToolsMovesWithItsHostView() throws {
        let fake = CEFAttachedPagesTests.FakeFork()
        let turn = CEFLayerHostingTests.Turn()
        let hostView = Self.hostView(turn)
        hostView.layerHosting.widget = .devTools
        let paneWindow = Self.window()
        paneWindow.contentView?.addSubview(hostView)
        hostView.layerHosting.pageWindowCreated(browser: Self.devTools, fork: fake.fork(widgets: [.devTools]))
        turn.end()
        let view = try #require(hostView.layerHosting.attachedPages.view(of: Self.devTools))

        let devToolsWindow = Self.window()
        devToolsWindow.contentView?.addSubview(hostView)
        turn.end()
        #expect(fake.attaches == [Self.devTools])
        #expect(view.window === devToolsWindow)
        #expect(hostView.layerHosting.attachedPages.shownView === view)

        hostView.layerHosting.stop()
        #expect(hostView.layerHosting.attachedPages.shownView == nil)
    }

    /// A first refusal of a DevTools frontend arms one retry, which the fork's next tracker read runs, as a
    /// pane's tab does: no present ever shows a DevTools again.
    @Test func aRefusedDevToolsAttachRetriesOnTheTrackersNextRead() throws {
        let fake = CEFAttachedPagesTests.FakeFork()
        fake.refusesOnce = [Self.devTools]
        let turn = CEFLayerHostingTests.Turn()
        let hostView = Self.hostView(turn)
        hostView.layerHosting.widget = .devTools
        hostView.layerHosting.pageWindowCreated(browser: Self.devTools, fork: fake.fork(widgets: [.devTools]))
        turn.end()
        #expect(hostView.layerHosting.attachedPages.retryArmed == [Self.devTools])

        hostView.layerHosting.trackerDidRead()
        turn.end()
        #expect(fake.attaches == [Self.devTools, Self.devTools])
        #expect(hostView.layerHosting.attachedPages.shownView != nil)
    }

    // MARK: The owners' wiring

    /// DEVTOOLS_OPENED gives the DevTools host view's page window its kind and the runtime's fork: on a fork that
    /// hosts only a tab's page the default counts the per-widget fallback and makes no fork call.
    @Test func anEmbeddedDevToolsReachesTheDecisionAsItsKind() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        let paneWindow = Self.window()
        paneWindow.contentView?.addSubview(tab.container)
        tab.container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let before = CEFHostView.trackerStats

        runtime.handle(.devToolsWillOpen(browser: Self.page))
        let views = try #require(tab.devToolsController.views)
        #expect(views.host.layerHosting.widget == .devTools)
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: true))
        Self.endTurn()

        #expect(views.host.layerHosting.isForkBacked)
        #expect(CEFHostView.trackerStats.hostingWidgetFallbacks == before.hostingWidgetFallbacks + 1)
        #expect(WidgetSpy.layerHosting.isEmpty)
    }

    @Test func aDevToolsOutsideACmuxViewMakesNoForkCall() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime)
        // No window: Chromium opens DevTools in a window of its own, which cmux never hosts.
        runtime.handle(.devToolsWillOpen(browser: Self.page))
        runtime.handle(.devToolsOpened(browser: Self.page, devTools: Self.devTools, docked: false))
        Self.endTurn()
        #expect(WidgetSpy.layerHosting.isEmpty)
        #expect(tab.devToolsController.views == nil)
    }

    /// An extension's popup window: once its popup host attached the hidden Chromium window to the panel's view,
    /// that view's page window is the window's tab, of kind `popupWindow`. On a fork that hosts only a tab's page
    /// the default counts the fallback.
    @Test func anAttachedExtensionPopupWindowIsThePanelViewsPageWindow() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = Self.tab(runtime)
        opener.host.adoptPopupWindow(window: 11, browser: 12, bounds: nil, opener: opener)
        let popup = try #require(runtime.tabsByBrowser[12])
        let host = popup.host
        #expect(host.isPopupHost)
        #expect(host.hostView.layerHosting.widget == .popupWindow)
        let panel = Self.window()
        panel.contentView?.addSubview(host.hostView)
        host.hostView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let before = CEFHostView.trackerStats

        #expect(host.attachPopupWindowIfNeeded(popup))
        #expect(WidgetSpy.attaches == [11])
        Self.endTurn()

        #expect(host.hostView.layerHosting.browser == 12)
        #expect(host.hostView.layerHosting.isForkBacked)
        #expect(CEFHostView.trackerStats.hostingWidgetFallbacks == before.hostingWidgetFallbacks + 1)
        #expect(WidgetSpy.layerHosting.isEmpty)
    }

    @Test func aPopupWindowThatDidNotAttachGetsNoPageWindow() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        WidgetSpy.attachResult = 0
        let opener = Self.tab(runtime)
        opener.host.adoptPopupWindow(window: 11, browser: 12, bounds: nil, opener: opener)
        let popup = try #require(runtime.tabsByBrowser[12])
        let panel = Self.window()
        panel.contentView?.addSubview(popup.host.hostView)

        #expect(popup.host.attachPopupWindowIfNeeded(popup))
        Self.endTurn()
        #expect(WidgetSpy.layerHosting.isEmpty)
        #expect(!popup.host.hostView.layerHosting.isForkBacked)
    }

    // MARK: Harness

    private static func fork(_ fake: CEFLayerHostingTests.FakeFork, widgets: Set<CEFLayerHosting.Widget>,
                             trackA: CEFLayerHosting.TrackA?) -> CEFLayerHosting.Fork {
        CEFLayerHosting.Fork(setLayerHosting: { browser, enabled in fake.fork.setLayerHosting(browser, enabled) },
                             trackA: trackA, hostedWidgets: widgets)
    }

    /// Layer hosting without the forced override, whose turns end on `schedule`.
    private static func hosting(schedule: @escaping CEFLayerHosting.Scheduler) -> CEFLayerHosting {
        CEFLayerHosting(isEnabled: { false }, schedule: schedule,
                        makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                        resizeDeadlineMs: { 0 }, liveResizeDeadlineMs: { 0 }, refreshIntervals: { [] }, afterCommit: { _ in })
    }

    /// A host view whose hosting ends its turns on `turn`, with the forced override on: a refused attach
    /// would show as a hosting call.
    private static func hostView(_ turn: CEFLayerHostingTests.Turn) -> CEFHostView {
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      afterCommit: { _ in })
        return CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), layerHosting: hosting)
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// An in-process runtime on the newest fork API whose app makes every Track A call with the feature on. It
    /// outlives the test: a tab's scheduled work reads it through an unowned reference.
    private static func runtime() throws -> (CEFRuntime, URL) {
        WidgetSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-widget-hosting-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(WidgetSpy.symbol), storage: CEFProfileStorage(root: root))
        runtime.pageHosting.trackA = .required
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A pane's tab whose browser is ``page``, its DevTools docked at the bottom (not the remembered layout).
    private static func tab(_ runtime: CEFRuntime) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: page)
        tab.devToolsController.layout = CEFDevToolsLayout()
        tab.container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return tab
    }

    /// Runs the blocks `CEFLayerHosting.atEndOfTurn` queued on the main run loop.
    private static func endTurn() {
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
    }
}

/// Stand-in shim functions for the newest fork API: `browser_set_layer_hosting` records each call and gives
/// context 7 when asked to host, `popup_window_attach` records the window and returns ``attachResult``,
/// `devtools_command` takes every command; every other function does nothing and returns 0.
private nonisolated enum WidgetSpy {
    nonisolated(unsafe) static var layerHosting: [(browser: Int32, enabled: Int32)] = []
    nonisolated(unsafe) static var attaches: [Int32] = []
    nonisolated(unsafe) static var attachResult: Int32 = 1

    static func reset() {
        layerHosting = []
        attaches = []
        attachResult = 1
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { browser, enabled in
            WidgetSpy.layerHosting.append((browser, enabled))
            return enabled == 1 ? 7 : 0
        }
        let attach: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32 = { window, _, _, _ in
            WidgetSpy.attaches.append(window)
            return WidgetSpy.attachResult
        }
        let command: @convention(c) (Int32, Int32, Int32, Int32) -> Int32 = { _, _, _, _ in 1 }
        // `CEFLayerHosting.embedderVisibilityForkAPI`.
        let forkAPIVersion: @convention(c) () -> Int32 = { 34 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_popup_window_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_devtools_command": unsafeBitCast(command, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
