import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// A WebKit tab a key just made shows its view, chrome and focused omnibar before its first page load starts: that
/// first `load` of a new `WKWebView` held the main thread 15-23 ms ahead of the omnibar's focus (`webkit_new` in
/// `cef-tab-bench.py`, focus p95 60 ms). `loadsAfter` runs it later (the app's after-frame commit); a navigation that
/// started first wins.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitFirstLoadAfterFrameTests {
    private func engine() -> WebKitEngine {
        WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(),
                     spareTab: WebKitSpareTab(clock: ManualClock(), activity: { 0 }, isTrackingMenu: { false }))
    }

    @Test func theFirstLoadStartsOnlyWhenLoadsAfterRunsIt() throws {
        let engine = engine()
        var later: [@MainActor () -> Void] = []
        let url = try #require(URL(string: "about:blank#first"))
        let tab = engine.makeWebKitTab(initialURL: url, loadsAfter: { later.append($0) })
        defer { tab.close(); engine.spareTab.drop() }
        #expect(tab.webView.url == nil && !tab.webView.isLoading, "the first load ran in the key's turn: \(String(describing: tab.webView.url))")
        #expect(later.count == 1)
        later.forEach { $0() }
        #expect(tab.webView.url == url || tab.webView.isLoading, "the later load did not start")
    }

    @Test func aNavigationThatStartedFirstWins() throws {
        let engine = engine()
        var later: [@MainActor () -> Void] = []
        let first = try #require(URL(string: "about:blank#first")), typed = try #require(URL(string: "about:blank#typed"))
        let tab = engine.makeWebKitTab(initialURL: first, loadsAfter: { later.append($0) })
        defer { tab.close(); engine.spareTab.drop() }
        tab.load(typed)
        later.forEach { $0() }
        #expect(tab.webView.url?.fragment != "first", "the later first load replaced the person's navigation")
    }

    @Test func withoutLoadsAfterTheFirstLoadStartsAtOnce() throws {
        let engine = engine()
        let url = try #require(URL(string: "about:blank#now"))
        let tab = engine.makeWebKitTab(initialURL: url)
        defer { tab.close(); engine.spareTab.drop() }
        #expect(tab.webView.url == url || tab.webView.isLoading)
    }
}
