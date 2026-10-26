import AppKit
@testable import CmuxNextBrowser
import Testing

/// Layer hosting on by default (p03-rendering-050, Track A): a pane's page window hosts on a fork
/// with the resize fence and embedder visibility (`CEFLayerHosting.trackAForkAPI`) with no tunable
/// set; older forks and the per-widget fallback (DevTools, popup windows, until p03-rendering-056)
/// keep the page's own window unless the benches' `layerHostingEveryWindow` is on; off hosts nothing.
@MainActor
@Suite struct CEFLayerHostingTrackADefaultTests {
    let fake = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func fork(trackA: Bool) -> CEFLayerHosting.Fork {
        fake.hostsByDefault = trackA
        return fake.fork
    }

    func makeHosting(enabled: @escaping () -> Bool = { BrowserResizeTunables.layerHosting.defaultValue },
                     everyWindow: Bool = BrowserResizeTunables.layerHostingEveryWindow.defaultValue,
                     widget: CEFLayerHosting.Widget) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: enabled, everyWindow: { everyWindow }, schedule: { $0() },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 0 }, liveResizeDeadlineMs: { 0 }, refreshIntervals: { [] })
        hosting.view = view
        hosting.widget = widget
        return hosting
    }

    @Test func hostingIsOnAndLimitedToTrackAPanePagesByDefault() {
        #expect(BrowserResizeTunables.layerHosting.defaultValue)
        #expect(!BrowserResizeTunables.layerHostingEveryWindow.defaultValue)
    }

    @Test func trackAComesAfterTheResizeFence() {
        #expect(CEFLayerHosting.trackAForkAPI > CEFLayerHosting.resizeFenceForkAPI)
        #expect(!CEFLayerHosting.hasResizeSync(apiVersion: CEFLayerHosting.trackAForkAPI),
                "a Track A fork never holds the commit for a resize deadline")
    }

    @Test func byDefaultOnlyAPanePageOnATrackAForkHosts() {
        let trackA = fork(trackA: true), older = fork(trackA: false)
        #expect(CEFLayerHosting.wantsHosting(enabled: true, everyWindow: false, fork: trackA, widget: .page))
        #expect(!CEFLayerHosting.wantsHosting(enabled: true, everyWindow: false, fork: older, widget: .page),
                "below Track A a page window that never orders in stops drawing")
        #expect(!CEFLayerHosting.wantsHosting(enabled: true, everyWindow: false, fork: trackA, widget: .devTools),
                "DevTools keeps its window until 056")
        #expect(!CEFLayerHosting.wantsHosting(enabled: true, everyWindow: false, fork: trackA, widget: .popup),
                "popup windows keep theirs until 056")
    }

    @Test func everyWindowHostsEachWidgetOnEveryForkAndOffHostsNone() {
        let trackA = fork(trackA: true), older = fork(trackA: false)
        for widget in [CEFLayerHosting.Widget.page, .devTools, .popup] {
            #expect(CEFLayerHosting.wantsHosting(enabled: true, everyWindow: true, fork: older, widget: widget),
                    "the A/B benches host every page window from API 26")
            #expect(!CEFLayerHosting.wantsHosting(enabled: false, everyWindow: true, fork: trackA, widget: widget))
            #expect(!CEFLayerHosting.wantsHosting(enabled: false, everyWindow: false, fork: trackA, widget: widget))
        }
    }

    @Test func aPanePageOnATrackAForkHostsWithNoTunableSet() throws {
        let hosting = makeHosting(widget: .page)
        hosting.pageWindowCreated(browser: 3, fork: fork(trackA: true))
        #expect(fake.calls.map(\.browser) == [3])
        #expect(fake.calls.map(\.enabled) == [true])
        #expect(try #require(hosting.page).contextID == 7)
    }

    @Test func aDockedDevToolsKeepsItsWindowWithNoTunableSet() {
        let hosting = makeHosting(widget: .devTools)
        hosting.pageWindowCreated(browser: 5, fork: fork(trackA: true))
        hosting.pageShown(browser: 5)
        #expect(fake.calls.isEmpty, "the fallback makes no fork call")
        #expect(hosting.page == nil)
    }

    @Test func aPopupWindowKeepsItsWindowWithNoTunableSet() {
        let hosting = makeHosting(widget: .popup)
        hosting.pageWindowCreated(browser: 6, fork: fork(trackA: true))
        hosting.pageShown(browser: 6)
        #expect(fake.calls.isEmpty)
        #expect(hosting.page == nil)
    }

    @Test func anOlderForkMakesNoHostingCallWithNoTunableSet() {
        let hosting = makeHosting(widget: .page)
        hosting.pageWindowCreated(browser: 3, fork: fork(trackA: false))
        hosting.pageShown(browser: 3)
        #expect(fake.calls.isEmpty)
        #expect(hosting.page == nil)
    }

    @Test func aDockedDevToolsHostsWithEveryWindow() throws {
        let hosting = makeHosting(everyWindow: true, widget: .devTools)
        hosting.pageWindowCreated(browser: 5, fork: fork(trackA: false))
        #expect(fake.calls.map(\.enabled) == [true])
        #expect(hosting.page != nil)
    }

    @Test func turningHostingOffAtAShowGivesThePageItsWindowBack() {
        var enabled = true
        let hosting = makeHosting(enabled: { enabled }, widget: .page)
        hosting.pageWindowCreated(browser: 3, fork: fork(trackA: true))
        #expect(hosting.page != nil)
        enabled = false
        hosting.pageShown(browser: 3)
        #expect(fake.calls.map(\.enabled) == [true, false])
        #expect(hosting.page == nil)
    }
}
