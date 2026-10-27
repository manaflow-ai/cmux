@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// Task p01-process-150: a relaunched cmux that adopted the crashed cmux's Chromium Host takes each restored tab's
/// page back by the tab's key instead of creating it, so the page is never reloaded: the pane's first tab takes its
/// page's window, page view token and Core Animation context, a later tab of the pane takes its page from that
/// window, and no create goes out for either. Each tab that gets a page tells the host its key. A page of a key whose
/// pane cannot show it closes at once; a page no tab took closes when the claim window ends; a closed page is
/// claimed by nobody; and this cmux's page view tokens start above the crashed cmux's. Against a spy remote shim.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFAdoptedPagesTests {
    private static let minted: Int32 = 1 << 20

    private static func page(_ key: String, browser: Int32, window: Int32 = 7, view: UInt64 = 3,
                             context: UInt32 = 0x1234) -> ChromiumHostAdoptedPage {
        ChromiumHostAdoptedPage(browser: browser, window: window, view: view, context: context, key: key)
    }

    // MARK: The claims

    @Test func aPanesFirstTabTakesItsPagesWindowAndLaterTabsTakeTheirsFromIt() {
        let panes = (Pane(), Pane())  // alive for the test: an identifier names a live object
        let first = ObjectIdentifier(panes.0), second = ObjectIdentifier(panes.1)
        var pages = CEFAdoptedPages([Self.page("a", browser: 1), Self.page("b", browser: 2), Self.page("c", browser: 3),
                                     Self.page("d", browser: 4, window: 8)])
        #expect(pages.claim(key: "a", pane: first, liveWindow: nil) == .bind(Self.page("a", browser: 1)))
        #expect(pages.claim(key: "b", pane: first, liveWindow: 7) == .bind(Self.page("b", browser: 2)))
        // Window 7 is the first pane's: another pane with no window cannot take a page of it.
        #expect(pages.claim(key: "c", pane: second, liveWindow: nil) == .discard(Self.page("c", browser: 3)))
        // A live pane takes no page of another window.
        #expect(pages.claim(key: "d", pane: first, liveWindow: 7) == .discard(Self.page("d", browser: 4, window: 8)))
        #expect(pages.claim(key: "a", pane: first, liveWindow: 7) == .noPage, "a page is taken once")
        #expect(pages.claim(key: "unknown", pane: first, liveWindow: nil) == .noPage)
        #expect(pages.bound == 2 && pages.discarded == 2 && pages.waiting == 0)
    }

    @Test func aClosedPageAndTheUnclaimedOnesLeave() {
        var pages = CEFAdoptedPages([Self.page("a", browser: 1), Self.page("b", browser: 2), Self.page("c", browser: 3)])
        pages.closed(browser: 2)
        let pane = Pane()
        #expect(pages.claim(key: "b", pane: ObjectIdentifier(pane), liveWindow: nil) == .noPage, "a closed page is no one's")
        #expect(pages.takeUnclaimed().map(\.browser) == [1, 3])
        #expect(pages.waiting == 0 && pages.discarded == 2)
        #expect(pages.takeUnclaimed().isEmpty)
    }

    // MARK: The runtime and its panes

    @Test func aRestoredTabShowsItsAdoptedPageWithNoCreate() async throws {
        let runtime = try await Self.runtime()
        runtime.takeAdoptedPages([Self.page("tab-a", browser: Self.minted + 2), Self.page("tab-b", browser: Self.minted + 3)],
                                 viewTokenFloor: 5)
        let (host, tab) = Self.pane(runtime, key: "tab-a")

        host.ensureCreated(tab)

        #expect(tab.browserID == Self.minted + 2, "the tab did not take its adopted page")
        #expect(runtime.tabsByBrowser[Self.minted + 2] === tab)
        #expect(AdoptSpy.state.withLock { $0.creates } == 0, "a new page was created for a tab whose page survived")
        #expect(host.window == .live(window: 7), "the pane did not take its page's Chromium window")
        #expect(host.hostedPageView?.wireToken == 3, "the page view does not name the window's parent view in the host")
        #expect(AdoptSpy.state.withLock { $0.pageKeys } == ["\(Self.minted + 2) tab-a"], "the host did not learn the tab's key")
        #expect(runtime.adoptedPages.bound == 1)

        // The pane's next tab takes its page from the pane's window: no tab_add.
        let second = CEFTab(id: BrowserTabID(rawValue: "tab-b"), profile: .default, host: host, runtime: runtime)
        host.add(second)
        host.ensureCreated(second)
        #expect(second.browserID == Self.minted + 3)
        #expect(AdoptSpy.state.withLock { $0.creates } == 0)
        #expect(AdoptSpy.state.withLock { $0.tabAdds } == 0, "a tab_add went for a page the window holds")
        #expect(AdoptSpy.state.withLock { $0.closes }.isEmpty, "a taken page was closed")
        #expect(runtime.adoptedPages.waiting == 0 && runtime.adoptedPagesDeadline != nil)
    }

    @Test func anAdoptedPageNoTabTookClosesWhenTheClaimWindowEnds() async throws {
        let runtime = try await Self.runtime()
        runtime.takeAdoptedPages([Self.page("tab-a", browser: Self.minted + 2), Self.page("gone", browser: Self.minted + 4)],
                                 viewTokenFloor: 5)
        #expect(runtime.adoptedPagesDeadline != nil, "nothing ends the claim window")
        let (host, tab) = Self.pane(runtime, key: "tab-a")
        host.ensureCreated(tab)

        runtime.closeUnclaimedAdoptedPages()  // the deadline's action

        #expect(AdoptSpy.state.withLock { $0.closes } == [Self.minted + 4], "the page no tab took still runs")
        #expect(tab.browserID == Self.minted + 2)
        #expect(runtime.adoptedPages.waiting == 0 && runtime.adoptedPagesDeadline == nil)
    }

    @Test func aPageAnotherPanesWindowHoldsClosesAndItsTabCreatesItsOwn() async throws {
        let runtime = try await Self.runtime()
        runtime.takeAdoptedPages([Self.page("tab-a", browser: Self.minted + 2), Self.page("tab-b", browser: Self.minted + 3)],
                                 viewTokenFloor: 5)
        let (first, a) = Self.pane(runtime, key: "tab-a")
        first.ensureCreated(a)
        let (second, b) = Self.pane(runtime, key: "tab-b")

        second.ensureCreated(b)

        #expect(AdoptSpy.state.withLock { $0.closes } == [Self.minted + 3], "the page that cannot show there was kept")
        #expect(AdoptSpy.state.withLock { $0.creates } == 1, "the tab did not create its own page")
        #expect(b.browserID == nil && b.isCreationPending, "the tab waits for its new window")
    }

    @Test func aPageThatClosedIsTakenByNoTab() async throws {
        let runtime = try await Self.runtime()
        runtime.takeAdoptedPages([Self.page("tab-a", browser: Self.minted + 2)], viewTokenFloor: 5)
        runtime.handle(.beforeClose(browser: Self.minted + 2))
        let (host, tab) = Self.pane(runtime, key: "tab-a")

        host.ensureCreated(tab)

        #expect(tab.browserID == nil)
        #expect(AdoptSpy.state.withLock { $0.creates } == 1, "the tab of a closed page did not create its own")
    }

    /// The crashed cmux's page views keep their tokens in the host: this cmux mints above them, and a page view made
    /// before the start takes a new token.
    @Test func pageViewTokensStartAboveTheCrashedCmuxs() async throws {
        let runtime = try await Self.runtime()
        let (host, _) = Self.pane(runtime, key: "tab-x")
        runtime.hosts[host.key] = host
        let early = host.hostedPage()
        #expect(early.wireToken == 1)

        runtime.takeAdoptedPages([], viewTokenFloor: 9)

        #expect(early.wireToken >= 9, "a page view kept a token the crashed cmux used")
        #expect(runtime.mintPageViewToken() > early.wireToken)
        #expect(runtime.adoptedPagesDeadline == nil, "no pages, no claim window")
    }

    // MARK: Fixtures

    private final class Pane {}

    /// A runtime in host mode over the spy that outlives the test (panes read it through an unowned reference).
    private static func runtime() async throws -> CEFRuntime {
        AdoptSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-adopted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(AdoptSpy.symbol), storage: CEFProfileStorage(root: root))
        let hostStart = try await HostRepliesHarness.attachedHost(over: { AdoptSpy.symbol($0) })
        hostStart.mapsClientIDs = true
        runtime.hostStart = hostStart
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    /// A pane with one tab of `key` and no window yet.
    private static func pane(_ runtime: CEFRuntime, key: String) -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: BrowserTabID(rawValue: key), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return (host, tab)
    }
}

/// The spy dylib: counts `create_window` and `tab_add`, records `close` and `cmux_remote_shim_set_page_key`, and has
/// fork API 30 (layer hosting); every other function returns 0.
private nonisolated enum AdoptSpy {
    struct State {
        var creates = 0
        var tabAdds = 0
        var closes: [Int32] = []
        var pageKeys: [String] = []
    }

    static let state = Mutex(State())

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = {
            _, _, _, _, _, _ in
            AdoptSpy.state.withLock { $0.creates += 1 }
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, _, _, _ in
            AdoptSpy.state.withLock { $0.tabAdds += 1 }
            return 0
        }
        let close: @convention(c) (Int32) -> Void = { browser in AdoptSpy.state.withLock { $0.closes.append(browser) } }
        let setPageKey: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = { browser, key in
            // SAFETY: the caller's NUL-terminated key, read during the call.
            let text = key.map { unsafe String(cString: $0) } ?? ""
            AdoptSpy.state.withLock { $0.pageKeys.append("\(browser) \(text)") }
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 30 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_page_key": unsafeBitCast(setPageKey, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
