import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// Layer hosting's default. The feature `cefLayerHosting` hosts a pane's page only where the
/// app makes every Track A call for the fork (the resize fence, embedder visibility); no fork API alone turns it on.
/// On a fork that hosts only a tab's page, DevTools and popup windows keep their own window (each kind on a fork
/// that hosts it is `CEFWidgetHostingTests`), and `debug.cef` counts why a page did not host. Only features decide
/// in the app: the Debug tunable `browserResize.layerHosting` reaches it only as the
/// feature's local override, resolved at launch; the benches' arm `cefLayerHostingEveryPage` and a test's
/// `override` seam host every page window from API 26.
@MainActor
@Suite(.serialized) struct CEFLayerHostingDefaultTests {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let fake = CEFLayerHostingTests.FakeFork()

    /// The fake fork's calls with `trackA` as the feature's view of it, and the benches' arm `everyPage`.
    func fork(trackA: CEFLayerHosting.TrackA?, everyPage: Bool = false) -> CEFLayerHosting.Fork {
        let fake = fake
        return CEFLayerHosting.Fork(setLayerHosting: { browser, enabled in fake.fork.setLayerHosting(browser, enabled) },
                                    trackA: trackA, hostsEveryPage: everyPage)
    }

    func makeHosting(override: Bool = false,
                     widget: CEFLayerHosting.Widget) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { override }, schedule: { $0() },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 0 }, liveResizeDeadlineMs: { 0 }, refreshIntervals: { [] })
        hosting.view = view
        hosting.widget = widget
        return hosting
    }

    // MARK: The decision

    @Test func theDefaultHostsAPanePageOnlyWithEveryTrackACall() {
        let host: (Bool, CEFLayerHosting.Fork, CEFLayerHosting.Widget) -> CEFLayerHosting.Hosting = {
            CEFLayerHosting.hosting(override: $0, fork: $1, widget: $2)
        }
        #expect(host(false, fork(trackA: nil), .page) == .off, "the feature off hosts nothing")
        #expect(host(false, fork(trackA: []), .page) == .missingTrackA)
        #expect(host(false, fork(trackA: [.resizeFence]), .page) == .missingTrackA,
                "without embedder visibility a page window that never orders in stops drawing")
        #expect(host(false, fork(trackA: [.embedderVisibility]), .page) == .missingTrackA,
                "without the fence a hosted page shows stale-size frames on each resize")
        #expect(host(false, fork(trackA: .required), .page) == .hosted)
        #expect(host(false, fork(trackA: .required), .devTools) == .widgetFallback)
        #expect(host(false, fork(trackA: .required), .popup) == .widgetFallback)
        #expect(host(false, fork(trackA: .required), .popupWindow) == .widgetFallback)
    }

    @Test func theForcedOverrideHostsEveryPageWindowOnAnyFork() {
        for widget in CEFLayerHosting.Widget.allCases {
            for trackA in [nil, [], CEFLayerHosting.TrackA.required] as [CEFLayerHosting.TrackA?] {
                #expect(CEFLayerHosting.hosting(override: true, fork: fork(trackA: trackA), widget: widget) == .hosted)
            }
        }
    }

    /// Feature `cefLayerHostingEveryPage`, the benches' on arm (`cef-layer-verify.py --mode on`): reachable while
    /// no fork has every Track A call, and it hosts what the tunable hosted before p12-perf-process-100.
    @Test func theBenchArmHostsEveryPageWindowWithoutTrackA() {
        for widget in CEFLayerHosting.Widget.allCases {
            for trackA in [nil, [], [.embedderVisibility], CEFLayerHosting.TrackA.required] as [CEFLayerHosting.TrackA?] {
                #expect(CEFLayerHosting.hosting(override: false, fork: fork(trackA: trackA, everyPage: true), widget: widget) == .hosted)
            }
        }
    }

    // MARK: The state machine

    @Test func aDockedDevToolsHostsWithTheBenchArm() throws {
        let hosting = makeHosting(widget: .devTools)
        hosting.pageWindowCreated(browser: 5, fork: fork(trackA: nil, everyPage: true))
        #expect(fake.calls.map(\.enabled) == [true])
        #expect(try #require(hosting.page).contextID == 7)
    }

    @Test func aDockedDevToolsHostsWithTheForcedOverrideAndNoFeature() throws {
        let hosting = makeHosting(override: true, widget: .devTools)
        hosting.pageWindowCreated(browser: 5, fork: fork(trackA: nil))
        #expect(fake.calls.map(\.enabled) == [true], "a test's forced override hosts DevTools")
        #expect(try #require(hosting.page).contextID == 7)
    }

    @Test func aPanePageHostsWithTheFeatureAndEveryTrackACall() throws {
        let hosting = makeHosting(widget: .page)
        hosting.pageWindowCreated(browser: 3, fork: fork(trackA: .required))
        #expect(fake.calls.map(\.browser) == [3])
        #expect(fake.calls.map(\.enabled) == [true])
        #expect(try #require(hosting.page).contextID == 7)
    }

    @Test func aPanePageWithoutEveryTrackACallKeepsItsWindowAndCountsWhy() {
        let before = CEFHostView.trackerStats
        let hosting = makeHosting(widget: .page)
        hosting.pageWindowCreated(browser: 3, fork: fork(trackA: [.resizeFence]))
        hosting.pageShown(browser: 3)
        #expect(fake.calls.isEmpty)
        #expect(hosting.page == nil)
        #expect(CEFHostView.trackerStats.hostingWithoutTrackA == before.hostingWithoutTrackA + 1)
        #expect(CEFHostView.trackerStats.hostingWidgetFallbacks == before.hostingWidgetFallbacks)
    }

    @Test func devToolsAndPopupsKeepTheirWindowOnAForkThatHostsOnlyAPageAndCountTheFallback() {
        for widget in [CEFLayerHosting.Widget.devTools, .popup, .popupWindow] {
            let before = CEFHostView.trackerStats
            let hosting = makeHosting(widget: widget)
            hosting.pageWindowCreated(browser: 6, fork: fork(trackA: .required))
            hosting.pageShown(browser: 6)
            #expect(fake.calls.isEmpty, "\(widget) made a fork call")
            #expect(hosting.page == nil)
            #expect(CEFHostView.trackerStats.hostingWidgetFallbacks == before.hostingWidgetFallbacks + 1)
        }
    }

    /// The Debug tunable on hosts nothing by itself: the app's hosting reads only the features (its fork's Track A
    /// calls and the benches' arm), and the tunable reaches them only as `cefLayerHosting`'s local override at launch.
    @Test func theAppsHostingNeverReadsTheDebugTunable() {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(BrowserResizeTunables.all)
        store.set("browserResize.layerHosting", .bool(true))
        defer { store.set("browserResize.layerHosting", nil) }
        let hosting = CEFLayerHosting(schedule: { $0() },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 0 }, liveResizeDeadlineMs: { 0 }, refreshIntervals: { [] })
        hosting.view = view
        for widget in CEFLayerHosting.Widget.allCases {
            hosting.widget = widget
            #expect(hosting.decide(fork(trackA: nil)) == .off, "\(widget) hosted with the feature off")
        }
        hosting.widget = .devTools
        hosting.pageWindowCreated(browser: 5, fork: fork(trackA: nil))
        #expect(fake.calls.isEmpty)
        #expect(hosting.page == nil)
    }

    @Test func theFeatureOffCountsNothing() {
        let before = CEFHostView.trackerStats
        let hosting = makeHosting(widget: .page)
        hosting.pageWindowCreated(browser: 3, fork: fork(trackA: nil))
        #expect(fake.calls.isEmpty)
        #expect(CEFHostView.trackerStats == before)
    }

    // MARK: The shim and the runtime

    @Test func noForkAPIAloneHostsByDefault() throws {
        let shim = try CEFShimLibrary.resolving(HostingSpy.symbol)
        #expect(CEFLayerHosting.Fork(shim: shim, apiVersion: CEFLayerHosting.forkAPI - 1, policy: CEFLayerHosting.Policy(trackA: .required)) == nil)
        for api: Int32 in [26, 27, 31, 32, 33, 40] {
            HostingSpy.reset()
            let fork = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: api))
            #expect(fork.trackA == nil, "fork API \(api)")
            let hosting = makeHosting(widget: .page)
            hosting.pageWindowCreated(browser: 3, fork: fork)
            #expect(HostingSpy.calls.isEmpty, "fork API \(api) hosted with no override and no feature")
        }
    }

    @Test func theRuntimeGivesItsFeatureAndTrackACallsToEachPageWindow() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        runtime.pageHosting.trackA = nil
        #expect(try #require(CEFLayerHosting.Fork(runtime: runtime)).trackA == nil)
        runtime.pageHosting.trackA = [.resizeFence]
        #expect(try #require(CEFLayerHosting.Fork(runtime: runtime)).trackA == [.resizeFence])
        #expect(try #require(CEFLayerHosting.Fork(runtime: runtime)).hostsEveryPage == false)
        runtime.pageHosting.hostsEveryPage = true
        #expect(try #require(CEFLayerHosting.Fork(runtime: runtime)).hostsEveryPage)
    }

    // MARK: The owners' widgets

    @Test func aPaneHostsPageHostsByDefault() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        #expect(host.hostView.layerHosting.widget == .page)
        host.hostView.layerHosting.pageWindowCreated(browser: 3, fork: CEFLayerHosting.Fork(runtime: runtime))
        Self.endTurn()
        #expect(HostingSpy.calls.first.map { [$0.browser, $0.enabled] } == [3, 1])
    }

    @Test func aPopupHostKeepsItsWindowByDefault() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: CEFPaneHost.popupPrefix + UUID().uuidString), profile: .default)
        let host = CEFPaneHost(key: key, runtime: runtime)
        #expect(host.hostView.layerHosting.widget == .popup)
        host.hostView.layerHosting.pageWindowCreated(browser: 4, fork: CEFLayerHosting.Fork(runtime: runtime))
        Self.endTurn()
        #expect(HostingSpy.calls.isEmpty)
    }

    @Test func aDockedDevToolsKeepsItsWindowByDefault() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let views = tab.devToolsController.makeViews(in: tab)
        #expect(views.host.layerHosting.widget == .devTools)
        views.host.layerHosting.pageWindowCreated(browser: 5, fork: CEFLayerHosting.Fork(runtime: runtime))
        Self.endTurn()
        #expect(HostingSpy.calls.isEmpty)
    }

    /// An in-process runtime (fork API 27) whose app makes every Track A call with the feature on. It outlives
    /// the test: a tab's scheduled work reads it through an unowned reference.
    private static func runtime() throws -> (CEFRuntime, URL) {
        HostingSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-layer-default-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(HostingSpy.symbol), storage: CEFProfileStorage(root: root))
        runtime.pageHosting.trackA = .required
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// Runs the blocks `CEFLayerHosting.atEndOfTurn` queued on the main run loop.
    private static func endTurn() {
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
    }
}

/// Stand-in shim functions: `browser_set_layer_hosting` records each call and gives context 7 when asked to
/// host; `fork_api_version` reports 27; every other function does nothing and returns 0.
private nonisolated enum HostingSpy {
    nonisolated(unsafe) static var calls: [(browser: Int32, enabled: Int32)] = []

    static func reset() { calls = [] }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { browser, enabled in
            HostingSpy.calls.append((browser, enabled))
            return enabled == 1 ? 7 : 0
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
