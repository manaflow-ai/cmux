import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Per-widget layer hosting (p03-rendering-056): from fork API 35 the feature `cefLayerHosting` hosts every kind
/// of page window a cmux view shows, not only a pane's page: an embedded DevTools (docked, and in cmux's DevTools
/// window after a dock move), a `window.open` popup host's window and an extension's attached popup window
/// (`chrome.windows.create` type popup). Each kind is driven through the fork seam (the shim's
/// `browser_set_layer_hosting`), without Chromium, and `debug.cef` `tracker.hosted_pages` counts each kind's view.
@MainActor
@Suite(.serialized) struct CEFWidgetHostingTests {
    private static let allKinds = Set(CEFLayerHosting.Widget.allCases)
    private static let page: Int32 = 1
    private static let devTools: Int32 = 2

    // MARK: The fork's kinds

    @Test func theForkHostsEveryKindFromAPI35() throws {
        #expect(CEFLayerHosting.widgets(apiVersion: CEFLayerHosting.forkAPI) == [.page])
        #expect(CEFLayerHosting.widgets(apiVersion: CEFLayerHosting.widgetHostingForkAPI - 1) == [.page])
        #expect(CEFLayerHosting.widgets(apiVersion: CEFLayerHosting.widgetHostingForkAPI) == Self.allKinds)
        let shim = try CEFShimLibrary.resolving(WidgetSpy.symbol)
        #expect(try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: 34)).hostedWidgets == [.page])
        #expect(try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: 35)).hostedWidgets == Self.allKinds)
    }

    @Test func eachKindHostsWithAForkThatHostsItAndEveryTrackACall() {
        let fake = CEFLayerHostingTests.FakeFork()
        for widget in CEFLayerHosting.Widget.allCases {
            let host = { (widgets: Set<CEFLayerHosting.Widget>, trackA: CEFLayerHosting.TrackA?) in
                CEFLayerHosting.hosting(override: false, fork: Self.fork(fake, widgets: widgets, trackA: trackA), widget: widget)
            }
            #expect(host(Self.allKinds, .required) == .hosted, "\(widget)")
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
            let hosting = CEFLayerHosting(isEnabled: { false }, schedule: { $0() },
                                          makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                          resizeDeadlineMs: { 0 }, liveResizeDeadlineMs: { 0 }, refreshIntervals: { [] }, afterCommit: { _ in })
            hosting.view = view
            hosting.widget = widget
            let before = CEFHostView.trackerStats

            hosting.pageWindowCreated(browser: 3, fork: Self.fork(fake, widgets: Self.allKinds, trackA: .required))

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

    // MARK: DevTools

    /// Docked: the DevTools page window hosts in its host view's layers once Chromium opened it. A dock move
    /// into cmux's DevTools window takes the view, so the page window, its context and its count go along with
    /// no fork call. A close turns hosting off for the DevTools browser and takes the count back.
    @Test func anEmbeddedDevToolsHostsDockedAndKeepsItsContextInItsOwnWindow() throws {
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
        #expect(WidgetSpy.layerHosting.isEmpty, "inside Chromium's creation stack the DevTools has no page window yet")
        Self.endTurn()

        #expect(WidgetSpy.layerHosting.map { [$0.browser, $0.enabled] } == [[Self.devTools, 1]])
        #expect(views.host.layerHosting.page?.contextID == 7)
        #expect(CEFHostView.trackerStats.hostedPagesByWidget["devtools", default: 0]
            == before.hostedPagesByWidget["devtools", default: 0] + 1)

        // The view leaves the pane for a window of its own, as `undockViews` adopts it.
        let devToolsWindow = Self.window()
        devToolsWindow.contentView?.addSubview(views.host)
        Self.endTurn()
        #expect(WidgetSpy.layerHosting.count == 1, "a dock move asked the fork again")
        #expect(views.host.layerHosting.page?.contextID == 7)
        #expect(CEFHostView.trackerStats.hostedPages == before.hostedPages + 1)

        runtime.handle(.devToolsClosed(browser: Self.page, devTools: Self.devTools))
        #expect(WidgetSpy.layerHosting.last.map { [$0.browser, $0.enabled] } == [Self.devTools, 0])
        #expect(views.host.layerHosting.page == nil)
        #expect(CEFHostView.trackerStats.hostedPages == before.hostedPages)
        #expect(CEFHostView.trackerStats.hostedPagesByWidget == before.hostedPagesByWidget)
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

    // MARK: Popups

    @Test func aPopupHostsPageWindowHosts() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: CEFPaneHost.popupPrefix + UUID().uuidString), profile: .default)
        let host = CEFPaneHost(key: key, runtime: runtime)
        #expect(host.hostView.layerHosting.widget == .popup)
        host.hostView.layerHosting.pageWindowCreated(browser: 4, fork: CEFLayerHosting.Fork(runtime: runtime))
        Self.endTurn()
        #expect(WidgetSpy.layerHosting.map { [$0.browser, $0.enabled] } == [[4, 1]])
        #expect(host.hostView.layerHosting.page?.hostedWidget == "popup")
    }

    /// An extension's popup window: its popup host attaches the hidden Chromium window to the panel's view, which
    /// then hosts that window's pixels. The tab's close (`chrome.windows.remove`) closes the window with it: the
    /// hosted view goes and its count with it, with no call for a window that is gone.
    @Test func anAttachedExtensionPopupWindowHostsInThePanelsView() throws {
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

        #expect(WidgetSpy.layerHosting.map { [$0.browser, $0.enabled] } == [[12, 1]])
        #expect(host.hostView.layerHosting.page?.contextID == 7)
        #expect(CEFHostView.trackerStats.hostedPagesByWidget["popup_window", default: 0]
            == before.hostedPagesByWidget["popup_window", default: 0] + 1)

        host.removed(popup)
        #expect(WidgetSpy.layerHosting.count == 1)
        #expect(host.hostView.layerHosting.page == nil)
        #expect(CEFHostView.trackerStats.hostedPagesByWidget == before.hostedPagesByWidget)
    }

    @Test func aPopupWindowThatDidNotAttachMakesNoForkCall() throws {
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
        #expect(popup.host.hostView.layerHosting.page == nil)
    }

    // MARK: Harness

    private static func fork(_ fake: CEFLayerHostingTests.FakeFork, widgets: Set<CEFLayerHosting.Widget>,
                             trackA: CEFLayerHosting.TrackA?) -> CEFLayerHosting.Fork {
        CEFLayerHosting.Fork(setLayerHosting: { browser, enabled in fake.fork.setLayerHosting(browser, enabled) },
                             trackA: trackA, hostedWidgets: widgets)
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// An in-process runtime on fork API 35 whose app makes every Track A call with the feature on. It outlives
    /// the test: a tab's scheduled work reads it through an unowned reference.
    private static func runtime() throws -> (CEFRuntime, URL) {
        WidgetSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-widget-hosting-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(WidgetSpy.symbol), storage: CEFProfileStorage(root: root))
        runtime.layerHostingTrackA = .required
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

/// Stand-in shim functions for fork API 35: `browser_set_layer_hosting` records each call and gives context 7
/// when asked to host, `popup_window_attach` records the window and returns ``attachResult``, `devtools_command`
/// takes every command; every other function does nothing and returns 0.
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
        // `CEFLayerHosting.widgetHostingForkAPI`.
        let forkAPIVersion: @convention(c) () -> Int32 = { 35 }
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
