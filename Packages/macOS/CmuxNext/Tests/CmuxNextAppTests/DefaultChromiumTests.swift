import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextBridge
import Foundation
import Testing

/// Chromium is the default engine: which engine each entrypoint picks, the
/// WebKit fallback (typed reason, one notice), recorded engines, and the
/// warm-start likelihood.
@MainActor
struct DefaultChromiumTests {
    // MARK: Pure resolution

    @Test func resolverMatrix() {
        func resolve(_ requested: String?, inherited: String? = nil, _ fallback: BrowserDefaultEngine = .chromium,
                     cef: CEFUnavailableReason? = nil) -> BrowserEngineResolver.Outcome {
            BrowserEngineResolver.resolve(requested: requested, inherited: inherited, defaultEngine: fallback, cefUnavailable: cef)
        }
        // No engine: the default, Chromium.
        #expect(resolve(nil) == .open(BrowserEngineChoice(engine: .cef)))
        #expect(resolve("") == .open(BrowserEngineChoice(engine: .cef)))
        #expect(resolve(nil, .webkit) == .open(BrowserEngineChoice(engine: .webkit)))
        // Missing CEF: WebKit with the reason, never silently.
        #expect(resolve(nil, cef: .notBundled) == .open(BrowserEngineChoice(engine: .webkit, fallback: .notBundled)))
        #expect(resolve(nil, .webkit, cef: .notBundled) == .open(BrowserEngineChoice(engine: .webkit)))
        // Explicit engines win; an explicit Chromium request is refused.
        #expect(resolve("webkit") == .open(BrowserEngineChoice(engine: .webkit)))
        #expect(resolve("cef", .webkit) == .open(BrowserEngineChoice(engine: .cef)))
        #expect(resolve("chromium", .webkit) == .open(BrowserEngineChoice(engine: .cef)))
        #expect(resolve("cef", cef: .startFailed("boom")) == .refuse(.startFailed("boom")))
        // Inherited engines (reopen, duplicate, popup) beat the default and fall back.
        #expect(resolve(nil, inherited: "webkit") == .open(BrowserEngineChoice(engine: .webkit, inherited: true)))
        #expect(resolve(nil, inherited: "cef", .webkit) == .open(BrowserEngineChoice(engine: .cef, inherited: true)))
        #expect(resolve(nil, inherited: "cef", cef: .notBundled)
            == .open(BrowserEngineChoice(engine: .webkit, fallback: .notBundled, inherited: true)))
        #expect(resolve("webkit", inherited: "cef") == .open(BrowserEngineChoice(engine: .webkit)))
    }

    @Test func fallbackNoticeShowsOnce() {
        let log = ChromiumFallbackLog()
        log.record(.notBundled, source: .newTab, surface: SurfaceID(rawValue: 1))
        log.record(.notBundled, source: .newTab, surface: SurfaceID(rawValue: 2))
        #expect(log.takeNotice(for: SurfaceID(rawValue: 3)) == nil, "not a fallback tab")
        #expect(log.takeNotice(for: SurfaceID(rawValue: 2)) == ChromiumFallbackLog.notice(for: .notBundled))
        #expect(log.takeNotice(for: SurfaceID(rawValue: 1)) == nil, "the notice never repeats")
        log.record(.startFailed("x"), source: .recordedTab, surface: SurfaceID(rawValue: 4))
        #expect(log.takeNotice(for: SurfaceID(rawValue: 4)) == nil)
        #expect(log.count == 3)
        #expect(log.lastReason == .startFailed("x"))
        #expect(log.lastSource == .recordedTab)
        #expect(log.notified)
    }

    // MARK: Entrypoints

    struct Harness {
        let services: AppServices
        let browserTabs: BrowserTabService
        let pane: PaneController
        let window: WindowController
        let recorder: BrowserTabTests.Recorder
        let state: WindowState
        var paneTarget: ActionTargetRef { ActionTargetRef(kind: .pane, id: "pane:3") }

        func teardown() {
            window.teardown()
            withExtendedLifetime((services, state)) {}
        }
    }

    /// One window showing a pane (`BrowserTabTests.tree`), with the daemon
    /// commands recorded. `extraTabs` are appended to that pane.
    func harness(cef: CEFUnavailableReason?, extraTabs: [String] = []) async throws -> Harness {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try Self.tree(extraTabs))
        let recorder = BrowserTabTests.Recorder()
        let browserTabs = try #require(services.cache.browserTabs)
        browserTabs.isAvailable = { true }
        browserTabs.cefUnavailable = { cef }
        var next: UInt64 = 20
        browserTabs.create = { pane, url, engine in
            recorder.created.append((pane, url, engine))
            next += 1
            return SurfaceID(rawValue: next)
        }
        let workspace = try #require(store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let window = WindowController(state: state, services: services, frame: nil)
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content != nil }
        let content = try #require(window.content)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let paneID = LayoutPaneIDFixture.id(paneModel)
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        content.layoutModel.focus(paneID)
        return Harness(services: services, browserTabs: browserTabs, pane: pane, window: window, recorder: recorder, state: state)
    }

    static func tree(_ extraTabs: [String]) throws -> DaemonTree {
        let tabs = [#"{"kind":"browser","name":"cdp","surface":4,"dead":false,"browser_renderer":"daemon"}"#] + extraTabs
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[\(tabs.joined(separator: ","))]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    static func frontendTab(surface: Int, engine: String, url: String = "https://a.test/") -> String {
        #"{"kind":"browser","name":"","surface":\#(surface),"dead":false,"browser_renderer":"frontend","browser_engine":"\#(engine)","url":"\#(url)"}"#
    }

    /// New Browser Tab (action, strip, CLI) and a terminal link open
    /// Chromium when nothing names an engine; WebKit only when asked for
    /// or when the default is WebKit.
    @Test func entrypointsDefaultToChromium() async throws {
        let h = try await harness(cef: nil)
        let registry = h.services.registry
        registry.perform("openBrowser", invocation: ActionInvocation(target: h.paneTarget))
        await BrowserTabTests.settle { h.recorder.created.count == 1 }
        #expect(h.recorder.created.last?.2 == .cef, "New Browser Tab")

        #expect(h.services.terminalDelegate.openLink(URL(string: "https://example.com/")!))
        await BrowserTabTests.settle { h.recorder.created.count == 2 }
        #expect(h.recorder.created.last?.2 == .cef, "Cmd-click a URL in a terminal")
        #expect(h.recorder.created.last?.1 == "https://example.com/")

        h.pane.newBrowserTab()
        await BrowserTabTests.settle { h.recorder.created.count == 3 }
        #expect(h.recorder.created.last?.2 == .cef, "the strip's + / omnibar new tab")

        registry.perform("openBrowser.webkit", invocation: ActionInvocation(target: h.paneTarget))
        await BrowserTabTests.settle { h.recorder.created.count == 4 }
        #expect(h.recorder.created.last?.2 == .webkit, "an explicit WebKit entry stays WebKit")

        // The palette/Settings action switches the default at once.
        registry.perform("browser.defaultEngine.webkit", invocation: ActionInvocation())
        #expect(h.browserTabs.preference.defaultEngine == .webkit)
        registry.perform("openBrowser", invocation: ActionInvocation(target: h.paneTarget))
        await BrowserTabTests.settle { h.recorder.created.count == 5 }
        #expect(h.recorder.created.last?.2 == .webkit)
        registry.perform("openBrowser", invocation: ActionInvocation(target: h.paneTarget, arguments: ["engine": .string("cef")]))
        await BrowserTabTests.settle { h.recorder.created.count == 6 }
        #expect(h.recorder.created.last?.2 == .cef, "an explicit engine beats the default")
        registry.perform("browser.defaultEngine.chromium", invocation: ActionInvocation())
        #expect(h.browserTabs.preference.defaultEngine == .chromium)
        #expect(h.browserTabs.fallbacks.count == 0)
        h.teardown()
    }

    /// CEF missing: default tabs open in WebKit, the reason is recorded, and
    /// the first fallback page shows one notice.
    @Test func missingChromiumFallsBackWithOneNotice() async throws {
        let h = try await harness(cef: .notBundled)
        h.services.registry.perform("openBrowser", invocation: ActionInvocation(target: h.paneTarget))
        await BrowserTabTests.settle { h.recorder.created.count == 1 }
        #expect(h.recorder.created.last?.2 == .webkit)
        #expect(h.browserTabs.fallbacks.lastReason == .notBundled)
        #expect(h.browserTabs.fallbacks.lastSource == .newTab)
        #expect(DebugCEF.report(h.services)["fallback"]?["count"]?.doubleValue == 1)
        #expect(DebugCEF.report(h.services)["unavailable"]?["code"]?.stringValue == "notBundled")

        // The daemon reports the new tab (surface 21) and a second fallback tab.
        h.pane.newBrowserTab()
        await BrowserTabTests.settle { h.recorder.created.count == 2 }
        h.services.daemon.store.apply(snapshot: try Self.tree([Self.frontendTab(surface: 21, engine: "webkit"),
                                                                Self.frontendTab(surface: 22, engine: "webkit")]))
        let tabs = try #require(h.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs)
        let first = try #require(tabs.first { $0.surface == SurfaceID(rawValue: 21) })
        let second = try #require(tabs.first { $0.surface == SurfaceID(rawValue: 22) })
        let firstEntry = try #require(h.services.cache.browser(for: first))
        #expect(firstEntry.chrome.noticeText == BrowserEngineStrings.fallbackNotBundled)
        let secondEntry = try #require(h.services.cache.browser(for: second))
        #expect(secondEntry.chrome.noticeText == nil, "one notice per process")
        #expect(h.browserTabs.fallbacks.notified)
        h.teardown()
    }

    /// A Chromium record keeps its engine: with CEF it stays Chromium; without
    /// it opens right away in WebKit (not a blank pane) and says why.
    @Test func recordedChromiumTabFallsBackWhenCEFIsMissing() async throws {
        let h = try await harness(cef: .startFailed("no framework"), extraTabs: [Self.frontendTab(surface: 30, engine: "cef")])
        let tab = try #require(h.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first { $0.surface == SurfaceID(rawValue: 30) })
        let entry = try #require(h.services.cache.browser(for: tab), "a WebKit page at once")
        #expect(entry.tab.engineKind == .webkit)
        #expect(entry.chrome.noticeText == BrowserEngineStrings.fallbackStartFailed)
        #expect(h.browserTabs.fallbacks.lastSource == .recordedTab)
        #expect(tab.browserEngine == "cef", "the record still names Chromium")
        h.teardown()
    }

    /// Duplicating a tab and a page's new-tab link keep the source's engine,
    /// even though new tabs default to Chromium.
    @Test func duplicatesAndPageRequestsKeepTheirEngine() async throws {
        let h = try await harness(cef: nil, extraTabs: [Self.frontendTab(surface: 31, engine: "webkit")])
        let tab = try #require(h.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first { $0.surface == SurfaceID(rawValue: 31) })
        await BrowserTabTests.settle { h.pane.stripModel.orderedTabs.contains { $0.id.rawValue == tab.id } }
        h.pane.select(StripTabID(tab.id))
        let refusal = h.services.registry.capturingRefusal {
            h.services.registry.perform("duplicateTab", invocation: ActionInvocation())
        }
        #expect(refusal == nil)
        await BrowserTabTests.settle { h.recorder.created.count == 1 }
        #expect(h.recorder.created.last?.2 == .webkit)

        let page = try #require(h.services.cache.browser(for: tab)).tab
        h.services.cache.pageRequests.browserTab(page, didRequest: .openURL(URL(string: "https://b.test/")!, .backgroundTab))
        await BrowserTabTests.settle { h.recorder.created.count == 2 }
        #expect(h.recorder.created.last?.2 == .webkit)
        #expect(h.recorder.created.last?.1 == "https://b.test/")
        h.teardown()
    }

    // MARK: Warm start

    @Test func browserTabsMakeChromiumLikelyOnlyWhileItIsTheDefault() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let store = services.daemon.store
        store.apply(snapshot: try Self.tree([]))
        #expect(AppServices.likelyFromTabs(services.machines, .chromium) == nil)
        store.apply(snapshot: try Self.tree([Self.frontendTab(surface: 40, engine: "webkit")]))
        #expect(AppServices.likelyFromTabs(services.machines, .chromium) == .browserTab)
        #expect(AppServices.likelyFromTabs(services.machines, .webkit) == nil)
        store.apply(snapshot: try Self.tree([Self.frontendTab(surface: 41, engine: "cef")]))
        #expect(AppServices.likelyFromTabs(services.machines, .webkit) == .restoredTab)
        withExtendedLifetime(services) {}
    }
}
