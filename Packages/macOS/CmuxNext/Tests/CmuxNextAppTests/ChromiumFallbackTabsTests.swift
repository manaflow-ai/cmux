import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextInput
import Foundation
import Testing

/// Behavior audit 4, P6: a tab whose record names Chromium opens in WebKit while Chromium cannot run (its
/// runtime downloads, or failed to). Each such tab says so on its page, not only the first one of the run,
/// and once Chromium is ready the tab moves to Chromium at the address it shows, and says that Chromium has
/// its own cookies.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ChromiumFallbackTabsTests {
    private static let first = URL(string: "https://example.com/a")!
    private static let second = URL(string: "https://example.com/b")!

    @Test func everyChromiumTabInWebKitSaysSoAndMovesToChromiumWhenChromiumIsReady() async throws {
        let f = FallbackFixture()
        let a = f.tab(surface: 4_101, url: Self.first)
        let b = f.tab(surface: 4_102, url: Self.second)
        defer { f.cache.release(a.id); f.cache.release(b.id) }

        let aPage = try #require(f.cache.browser(for: a), "the WebKit page was not made")
        let bPage = try #require(f.cache.browser(for: b), "the WebKit page was not made")
        #expect(aPage.tab.engineKind == .webkit && bPage.tab.engineKind == .webkit)
        #expect(aPage.chrome.noticeText != nil, "the first Chromium tab in WebKit does not say so")
        #expect(bPage.chrome.noticeText != nil, "a later Chromium tab in WebKit does not say so")

        f.reason.value = nil  // the runtime is installed: Chromium can open tabs
        guard f.cache.browser(for: a) == nil else {
            Issue.record("the tab stays in WebKit once Chromium is ready")
            return
        }
        await f.ready(a)
        let moved = try #require(f.cache.existingBrowser(a.id))
        #expect(moved.tab.engineKind == .cef, "the tab did not move to Chromium")
        #expect(f.made.urls == [Self.first], "the Chromium page did not keep the tab's address")
        #expect(moved.chrome.noticeText != nil, "the moved tab does not say its cookies differ")
    }
}

/// A cache whose Chromium cannot open tabs while `reason` is set, with mock Chromium pages.
@MainActor
private final class FallbackFixture {
    final class Reason {
        var value: CEFUnavailableReason? = .downloading(fraction: nil)
    }

    let reason = Reason()
    let made = MadeURLs()
    let cache: TabContentCache
    private var tabs: [String: TabModel] = [:]
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var arrived: Set<String> = []

    init() {
        _ = NSApplication.shared
        let engine = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
        cache = TabContentCache(daemon: DaemonService(), chromium: ChromiumEngineSlot(engine), fileInput: NoFileInput(), mainWork: linklessMainWork())
        cache.defersRestoredPages = false
        cache.browserTabs.cefUnavailable = { [reason] in reason.value }
        cache.chromiumNow.runs = { false }
        cache.makeCEFTab = { [made] configuration in
            made.urls.append(configuration.initialURL)
            return MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
        }
        cache.findTab = { [weak self] key in self?.tabs[key] }
        cache.onBrowserReady = { [weak self] key in self?.arrive(key) }
    }

    /// A browser tab whose record names Chromium, at `url`.
    func tab(surface: UInt64, url: URL) -> TabModel {
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: url.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        tabs[tab.id] = tab
        return tab
    }

    /// Returns once `tab` has a Chromium page.
    func ready(_ tab: TabModel) async {
        if arrived.remove(tab.id) != nil { return }
        await withCheckedContinuation { waiting[tab.id] = $0 }
    }

    private func arrive(_ key: String) {
        guard cache.existingBrowser(key)?.tab.engineKind == .cef else { return }
        if let waiter = waiting.removeValue(forKey: key) { waiter.resume() } else { arrived.insert(key) }
    }
}

@MainActor
private final class MadeURLs {
    var urls: [URL?] = []
}
