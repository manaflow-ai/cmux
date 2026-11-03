import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Cmd-N in NIGHTLY 1.0.0-nightly.3968001295301 sometimes left the new workspace's New Tab field
/// without the keyboard: the page (a prewarmed spare whose browser already existed) asked for focus
/// a moment before its Chromium window showed, `setFocused(true)` refused a hidden page, and only a
/// browser's creation (`attach`) replayed that ask. The page then showed with no focus, and the
/// focus applier, which had already asked, never asked again.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFDeferredFocusTests {
    /// A page with its browser asks for focus before its view is in a window; it gets it once it shows.
    @Test func focusAskedBeforeThePageShowsIsGrantedWhenItShows() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 7)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty, "a page that does not show takes no focus")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        #expect(FocusSpyShim.granted == [7])
    }

    /// A shown page the content lifecycle hid (its first paint not there yet) asks for focus; it gets
    /// it when the lifecycle shows it again.
    @Test func focusAskedWhileTheLifecycleHidThePageIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        tab.setContentVisible(false)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty)

        tab.setContentVisible(true)
        #expect(FocusSpyShim.granted == [8])
    }

    /// An ask taken back (focus moved on) before the page showed is not granted later.
    @Test func focusTakenBackBeforeThePageShowsIsNotGranted() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 9)

        tab.setFocused(true)
        tab.setFocused(false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        #expect(FocusSpyShim.granted.isEmpty)
    }

    /// NIGHTLY 1.0.0-nightly.4093446036501 beachballed for good: a workspace switch hid an ancestor of
    /// the focused page's view. Chromium ordered the page window out inside AppKit's hide walk, before
    /// the page's own `viewDidHide`; the cmux window took the keys, the focus applier asked again, and
    /// the grant showed the page window again, around and around in one main-thread turn. A page
    /// under a hidden ancestor takes no focus; it gets it when its view shows again.
    @Test func focusAskedWhileAnAncestorHidesIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 10)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Hidden first in AppKit's walk, as Chromium's view was: it asks for focus mid-hide.
        let chromium = HideSpyView(frame: workspace.bounds)
        workspace.addSubview(chromium)
        workspace.addSubview(tab.contentView)
        try #require(window.contentView).addSubview(workspace)
        FocusSpyShim.granted = []
        chromium.onHide = { tab.setFocused(true) }

        workspace.isHidden = true
        #expect(FocusSpyShim.granted.isEmpty, "a page under a hidden ancestor was given focus: \(FocusSpyShim.granted)")

        chromium.onHide = nil
        workspace.isHidden = false
        #expect(FocusSpyShim.granted == [10])
    }

    /// The same ask from inside the page's own view (where Chromium's view sits), whichever order
    /// AppKit tells a view and its subviews that an ancestor hid.
    @Test func focusAskedFromInsideThePageWhileAnAncestorHidesIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 11)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        try #require(window.contentView).addSubview(workspace)
        workspace.addSubview(tab.contentView)
        let chromium = HideSpyView(frame: tab.contentView.bounds)
        tab.contentView.addSubview(chromium)
        FocusSpyShim.granted = []
        chromium.onHide = { tab.setFocused(true) }

        workspace.isHidden = true
        #expect(FocusSpyShim.granted.isEmpty, "a page under a hidden ancestor was given focus: \(FocusSpyShim.granted)")

        chromium.onHide = nil
        workspace.isHidden = false
        #expect(FocusSpyShim.granted == [11])
    }

    /// reopen-browser-plain-keys cycle B (REOPEN VIDEO 7660, 7710): keys sent on when the browser existed reached the
    /// empty document the restore replaced; keys sent on at the restored document's commit reached a page whose
    /// script had not run (its focused field and key listener did not exist yet). The page is ready for keys once a
    /// real (not blank) document finished loading. Events in CEF's order: loading starts, the commit, the load end,
    /// loading stops.
    @Test func aTabIsReadyForKeysOnceARealDocumentLoaded() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 16)
        #expect(!tab.pageReady, "keys sent on when the browser exists reach the empty document the restore replaces")
        Self.load(runtime, 16, "about:blank")
        #expect(!tab.pageReady, "a blank document's load is not the restored page")
        runtime.handle(.loadingState(browser: 16, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 16, url: "https://example.com/", fromPost: false))
        #expect(!tab.pageReady, "keys sent on at the commit reach a page whose script has not run")
        runtime.handle(.loadEnd(browser: 16, httpStatus: 200))
        runtime.handle(.loadingState(browser: 16, loading: false, canGoBack: false, canGoForward: false))
        #expect(tab.pageReady)
        #expect(reported() == 1, "the tab did not say its real document loaded")
        Self.load(runtime, 16, "https://example.com/next")
        #expect(reported() == 1, "a later navigation ended a hold again")
    }

    /// reopen-browser-plain-keys cycle B, v8 (REOPEN VIDEO 7801: 1 of 3; in every round, pass or fail, the held keys went
    /// on about 46 ms after the page attached, so the page's readiness did not gate them): a navigation that the next
    /// one replaces ends in an aborted load (ERR_ABORTED, -3), and a load end comes while the next navigation is on its
    /// way. Neither is the page the keys must reach: it is ready once Chromium stopped loading (CEF reports that after
    /// every load end and error of the load) with a real document loaded, or with an error page.
    @Test func aTabIsReadyForKeysOnlyOnceLoadingStoppedOnARealDocument() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 17)
        runtime.handle(.loadingState(browser: 17, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadError(browser: 17, code: -3, text: "net::ERR_ABORTED", url: "https://example.com/", chromiumInterstitial: false))
        #expect(!tab.pageReady, "an aborted load (a navigation the next one replaced) is no page")
        runtime.handle(.loadStart(browser: 17, url: "https://example.com/", fromPost: false))
        runtime.handle(.loadEnd(browser: 17, httpStatus: 200))
        #expect(!tab.pageReady, "a load end while Chromium still loads: the next navigation replaces this document")
        runtime.handle(.loadStart(browser: 17, url: "https://example.com/?c=1", fromPost: false))
        runtime.handle(.loadEnd(browser: 17, httpStatus: 200))
        #expect(!tab.pageReady, "ready before Chromium stopped loading")
        runtime.handle(.loadingState(browser: 17, loading: false, canGoBack: false, canGoForward: false))
        #expect(tab.pageReady, "loading stopped on a real document, and the page is not ready")
        #expect(reported() == 1)
        let (failing, failed) = try Self.readyTab(runtime, browser: 18)
        runtime.handle(.loadingState(browser: 18, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadError(browser: 18, code: -105, text: "net::ERR_NAME_NOT_RESOLVED", url: "https://nowhere.invalid/", chromiumInterstitial: false))
        runtime.handle(.loadingState(browser: 18, loading: false, canGoBack: false, canGoForward: false))
        #expect(failing.pageReady && failed() == 1, "an error page takes keys: the hold must not wait for its bound")
    }

    /// Lead on STATUS 7828: the second ready-for-keys in the journal (about 430 ms after the first) was another page's
    /// (an app page with no key hold). One browser reports once, whatever loads after; a browser attached again (a
    /// renderer restart) is a new page and reports once when it is ready again, never before.
    @Test func aTabReportsReadyOncePerBrowserAndAgainOnlyAfterItIsReadyAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 19)
        Self.load(runtime, 19, "https://example.com/")
        Self.load(runtime, 19, "https://example.com/again")
        runtime.handle(.loadingState(browser: 19, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadError(browser: 19, code: -105, text: "net::ERR_NAME_NOT_RESOLVED", url: "https://nowhere.invalid/", chromiumInterstitial: false))
        runtime.handle(.loadingState(browser: 19, loading: false, canGoBack: false, canGoForward: false))
        #expect(reported() == 1, "one browser reported ready \(reported()) times")
        tab.attach(browser: 19)
        #expect(!tab.pageReady && reported() == 1, "a browser attached again was ready before its page loaded")
        Self.load(runtime, 19, "https://example.com/")
        #expect(tab.pageReady && reported() == 2)
    }

    /// Review of #32633: a Chromium New Tab page (a blank document, `about:blank`) never counted as ready, so Cmd-L
    /// after Escape waited the whole bound; and every new page waited for its document. Only a tab that comes back from
    /// the session (a reopen, a hibernation wake) waits for its first document; another page takes keys once Chromium
    /// created it. A restored blank tab is ready once its blank document loaded.
    @Test func onlyARestoredTabWaitsForItsDocumentAndABlankOneCountsWhenItIsTheTabs() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fresh, freshReported) = try Self.readyTab(runtime, browser: 20, restored: nil)
        #expect(fresh.pageReady && freshReported() == 1, "a New Tab page was not ready once Chromium created it")
        Self.load(runtime, 20, "about:blank")
        #expect(freshReported() == 1)
        let (blank, blankReported) = try Self.readyTab(runtime, browser: 21, restored: "about:blank")
        #expect(!blank.pageReady)
        Self.load(runtime, 21, "about:blank")
        #expect(blank.pageReady && blankReported() == 1, "a restored blank tab never got ready: its keys waited the whole bound")
    }

    /// A shown tab whose browser Chromium created, and a count of its ready-for-keys reports. `restored`: the URL a tab
    /// that comes back from the session shows (nil: a new page).
    private static func readyTab(_ runtime: CEFRuntime, browser: Int32, restored: String? = "https://example.com/") throws -> (CEFTab, () -> Int) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        if let restored, let url = URL(string: restored) { (tab.awaitsFirstDocument, tab.pendingURL) = (true, url) }
        final class Count { var value = 0 }
        let count = Count()
        tab.onReadyForKeys = { count.value += 1 }
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        return (tab, { count.value })
    }

    /// One whole load of `url` in CEF's order.
    private static func load(_ runtime: CEFRuntime, _ browser: Int32, _ url: String) {
        runtime.handle(.loadingState(browser: browser, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: browser, url: url, fromPost: false))
        runtime.handle(.loadEnd(browser: browser, httpStatus: 200))
        runtime.handle(.loadingState(browser: browser, loading: false, canGoBack: false, canGoForward: false))
    }

    /// A tab whose browser Chromium made (`afterCreated`), its view in no window yet.
    private func createdTab(_ runtime: CEFRuntime, browser: Int32) throws -> (CEFTab, CEFPaneHost) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        #expect(tab.browserID == browser)
        FocusSpyShim.granted = []
        return (tab, host)
    }
}

/// A view that runs `onHide` when an ancestor hides it.
private final class HideSpyView: NSView {
    var onHide: (() -> Void)?

    override func viewDidHide() {
        super.viewDidHide()
        onHide?()
    }
}

/// Stand-in shim functions: `cmux_shim_set_focus` records the browsers given focus,
/// `cmux_shim_create_window` reports the browser started; every other function does nothing.
private nonisolated enum FocusSpyShim {
    nonisolated(unsafe) static var granted: [Int32] = []
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    @MainActor static var runtimes: [CEFRuntime] = []

    @MainActor static func runtime() throws -> (CEFRuntime, URL) {
        granted = []
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-focus-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try library(), storage: CEFProfileStorage(root: root))
        runtimes.append(runtime)
        return (runtime, root)
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let setFocus: @convention(c) (Int32, Int32) -> Void = { browser, focused in if focused == 1 { FocusSpyShim.granted.append(browser) } }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_focus": unsafeBitCast(setFocus, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
