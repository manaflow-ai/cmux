#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBrowser
import CmuxNextBrowserTabs
@testable import CmuxNextApp
import CmuxNextOracle
import Foundation
import Testing

/// The oracle's `tabs` facet read through the engine-neutral `BrowserTab` protocol (p15-oracle-037): the same
/// page history gives the same tab on WebKit and Chromium except `engine`; with no page the daemon record answers;
/// titles go in only as hashes; the app's facet list provides `tabs`.
/// Run: `swift test --filter OracleBrowserTabTests`.
@MainActor @Suite(.serialized) struct OracleBrowserTabTests {
    /// A page on `kind` that loaded two addresses, was titled, zoomed and muted.
    private func page(_ kind: BrowserEngineKind) throws -> MockBrowserTab {
        let page = MockBrowserEngine(kind: kind).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/a")))
        page.load(try #require(URL(string: "https://example.com/b")))
        page.simulate(.titleChanged("Example B"))
        page.setZoom(1.25)
        page.setAudioMuted(true)
        return page
    }

    @Test func bothEnginesGiveTheSameTabButTheirEngine() throws {
        let record = OracleTabsFacet.Tab.Record(url: "https://stale.example/", title: "Stale", zoom: 2, engine: "webkit")
        let webkit = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: true, page: try page(.webkit), record: record, hibernated: false)
        let cef = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: true, page: try page(.cef), record: record, hibernated: false)
        #expect(webkit.engine == "webkit")
        #expect(cef.engine == "cef")
        var cefAsWebKit = cef
        cefAsWebKit.engine = "webkit"
        #expect(cefAsWebKit == webkit)

        #expect(cef.url == "https://example.com/b")
        #expect(cef.titleHash == OracleTabsFacet.Tab.hash("Example B"))
        #expect(cef.loadState == .finished)
        #expect(cef.canGoBack)
        #expect(cef.zoom == 1.25)
        #expect(cef.muted)
        #expect(cef.pinned)
        #expect(!cef.crashed)
    }

    @Test func aCrashedPageIsCrashedOnEitherEngine() throws {
        for kind in BrowserEngineKind.allCases {
            let page = try page(kind)
            page.simulate(.processExited(BrowserProcessExit(reason: .crashed)))
            let tab = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: false, page: page, record: .init(), hibernated: false)
            #expect(tab.crashed, "\(kind)")
        }
    }

    @Test func aTabWithNoPageReadsItsRecord() {
        let record = OracleTabsFacet.Tab.Record(url: "https://example.com/", title: "Saved", zoom: 1.5, engine: "cef")
        let tab = OracleTabsFacet.Tab.browser(id: "tab_2", pinned: false, page: nil, record: record, hibernated: true)
        #expect(tab.engine == "cef")
        #expect(tab.url == "https://example.com/")
        #expect(tab.titleHash == OracleTabsFacet.Tab.hash("Saved"))
        #expect(tab.zoom == 1.5)
        #expect(tab.loadState == .unloaded)
        #expect(tab.hibernated)
    }

    @Test func titlesAreHashesOnly() {
        // sha256("abc"), the FIPS 180-2 test vector.
        #expect(OracleTabsFacet.Tab.hash("abc") == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let page = OracleTabsFacet.Tab.page(id: "local-page:settings:1", page: "settings", title: "Settings")
        #expect(page.titleHash == OracleTabsFacet.Tab.hash("Settings"))
        #expect(OracleTabsFacet.Tab.browser(id: "tab_4", pinned: false, page: nil, record: .init(), hibernated: false).titleHash == nil)
    }

    @Test func theAppListProvidesTabs() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.tabs))
        #expect(facets.duplicates.isEmpty)
        let snapshot = try #require(try facets.beginCapture([.tabs]).completed)
        guard case .array? = snapshot["tabs"]?["panes"] else {
            Issue.record("tabs has no panes list: \(String(describing: snapshot["tabs"]))")
            return
        }
    }
}
#endif
