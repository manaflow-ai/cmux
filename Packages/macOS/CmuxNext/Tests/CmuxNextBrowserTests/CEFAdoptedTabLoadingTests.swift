import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence, 2026-11-15: "often when i click something on website that opens a new tab, i see blank
/// omnibar (it says search or type URL) and i don't see the proper loading state". Chrome's omnibox
/// shows the new tab's address and its loading state from the first frame: the omnibox reads the
/// visible entry (`LocationBarModelImpl::GetURL`, `NavigationControllerImpl::GetVisibleEntry`), which
/// is the pending entry of an unmodified new tab. cmux lost both:
/// - target=_blank (noopener) and Cmd-click: Chromium starts the load inside the call that creates
///   the tab (`WebContentsImpl::CreateNewWindow` runs `LoadURLWithParams` after `AddNewContents`),
///   while cmux adopts the tab on a later turn; the load's events reached no tab and were dropped.
/// - window.open: the opener's renderer starts the load after the adoption, but CEF reports an
///   address only at commit (`OnAddressChange` from `DidFinishNavigation`).
///
/// Events go through `CEFShimEvent(kind:...)`, the shim's own wire format: kind 7 is
/// `CMUX_SHIM_LOADING_STATE` (a = loading | back << 1 | forward << 2, s1 = the visible entry's URL).
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFAdoptedTabLoadingTests {
    static let opener: Int32 = 10
    static let child: Int32 = 11
    static let target = "https://example.com/next"

    /// A target=_blank link: the load starts before the fork has placed the new tab in the pane's
    /// window. Once adopted, the tab shows the link's address and its loading state at once.
    @Test func aTabAPageOpenedShowsTheLoadThatStartedBeforeItsAdoption() async throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try Self.liveHost(runtime)
        var created = CEFCreatedBy(opener: Self.opener, disposition: .newForegroundTab, userGesture: true, features: nil)
        created.url = Self.target

        // Chromium creates the tab in no pane window yet (fork API 8: it waits for the insertion).
        runtime.handle(.afterCreated(browser: Self.child, request: 0, window: 0, created: created))
        // ... and starts the link's load in the same call (CreateNewWindow's LoadURLWithParams).
        runtime.handle(Self.loadingStarted(Self.child, visible: Self.target))
        runtime.handle(Self.progress(Self.child, 0.3))
        #expect(runtime.tabsByBrowser[Self.child] == nil, "not adopted yet")

        // The fork inserts it into the pane's window; cmux adopts it on the next turn.
        runtime.handle(CEFShimEvent(kind: 16, browser: Self.child, request: CEFForkTabEvent.inserted.rawValue, a: 1, b: 0, s1: "", s2: ""))
        let tab = try await Self.adopted(Self.child, runtime)
        #expect(tab.host === host)

        #expect(tab.state.isLoading, "the load Chromium began before the adoption shows as loading")
        #expect(tab.state.url?.absoluteString == Self.target, "the omnibar shows the link's address, not an empty field")
        #expect(tab.state.progress >= 0.3)

        // The commit still takes over, as for any load.
        runtime.handle(CEFShimEvent(kind: 8, browser: Self.child, request: 0, a: 0, b: 0, s1: Self.target + "?r=1", s2: ""))
        #expect(tab.state.url?.absoluteString == Self.target + "?r=1")
    }

    /// window.open: the new tab is adopted before its opener's renderer starts the load. The
    /// address shows from the load's start (Chromium's visible entry), not only at commit.
    @Test func aWindowOpenLoadShowsItsAddressFromItsStart() async throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.liveHost(runtime)
        var created = CEFCreatedBy(opener: Self.opener, disposition: .newForegroundTab, userGesture: true, features: nil)
        created.url = Self.target

        // Created in the pane's live window: adopted at once.
        runtime.handle(.afterCreated(browser: Self.child, request: 0, window: 1, created: created))
        let tab = try #require(runtime.tabsByBrowser[Self.child])
        #expect(!tab.state.isLoading)

        runtime.handle(Self.loadingStarted(Self.child, visible: Self.target))
        #expect(tab.state.isLoading)
        #expect(tab.state.url?.absoluteString == Self.target, "the pending load's address, before any response")
    }

    /// A page that navigates itself keeps its committed address until the new document commits:
    /// Chromium's visible entry is the committed one then (no spoofing by a page's own load).
    @Test func aPageLoadingInItsOwnTabKeepsTheCommittedAddressUntilCommit() async throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try Self.liveHost(runtime)
        let page = try #require(host.visibleTab)
        runtime.handle(Self.loadingStarted(Self.opener, visible: ""))
        runtime.handle(CEFShimEvent(kind: 8, browser: Self.opener, request: 0, a: 0, b: 0, s1: "https://a.example/", s2: ""))
        runtime.handle(CEFShimEvent(kind: 9, browser: Self.opener, request: 0, a: 200, b: 0, s1: "", s2: ""))
        runtime.handle(CEFShimEvent(kind: 7, browser: Self.opener, request: 0, a: 0, b: 0, s1: "", s2: ""))
        #expect(page.state.url?.absoluteString == "https://a.example/")

        // A link click in the page: the visible entry is still the committed page.
        runtime.handle(Self.loadingStarted(Self.opener, visible: "https://a.example/"))
        #expect(page.state.isLoading)
        #expect(page.state.url?.absoluteString == "https://a.example/")
    }

    /// An adopted tab's early events are its own: a browser no one adopts keeps none, and a browser
    /// that closed before its adoption leaves nothing behind.
    @Test func earlyEventsAreKeptOnlyForBrowsersWaitingForAdoption() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.liveHost(runtime)
        runtime.handle(Self.loadingStarted(42, visible: Self.target))
        #expect(runtime.orphans.takeEarlyEvents(42).isEmpty, "no browser Chromium created for a page")

        var created = CEFCreatedBy(opener: Self.opener, disposition: .newForegroundTab, userGesture: true, features: nil)
        created.url = Self.target
        runtime.handle(.afterCreated(browser: Self.child, request: 0, window: 0, created: created))
        for _ in 0..<(CEFOrphanTabs.maximumEarlyEvents + 5) { runtime.handle(Self.progress(Self.child, 0.5)) }
        runtime.handle(CEFShimEvent(kind: 3, browser: Self.child, request: 0, a: 0, b: 0, s1: "", s2: ""))
        #expect(runtime.orphans.takeEarlyEvents(Self.child).isEmpty, "a closed browser keeps nothing")
    }

    // MARK: Fixtures

    static func loadingStarted(_ browser: Int32, visible: String) -> CEFShimEvent {
        CEFShimEvent(kind: 7, browser: browser, request: 0, a: 1, b: 0, s1: visible, s2: "")
    }

    static func progress(_ browser: Int32, _ value: Double) -> CEFShimEvent {
        CEFShimEvent(kind: 11, browser: browser, request: 0, a: Int64(value * 1000), b: 0, s1: "", s2: "")
    }

    /// The tab cmux adopted for `browser`, once the deferred adoption ran (a main-actor turn).
    static func adopted(_ browser: Int32, _ runtime: CEFRuntime) async throws -> CEFTab {
        for _ in 0..<50 {
            if let tab = runtime.tabsByBrowser[browser] { return tab }
            await Task.yield()
        }
        return try #require(runtime.tabsByBrowser[browser], "adopted on a later turn")
    }

    /// A runtime that outlives the test (a shown tab's scheduled work reads it after the test).
    static func runtime() throws -> (CEFRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-adopted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try AdoptionShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A pane showing a Chromium page (browser 10) in its live window (1).
    static func liveHost(_ runtime: CEFRuntime) throws -> CEFPaneHost {
        // Through the runtime, as a pane's host is made: the runtime finds it by the window a new tab is in.
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: opener, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        #expect(host.isLive)
        #expect(first.browserID == opener)
        return host
    }
}

/// Stand-in shim: `cmux_shim_create_window` reports the window started, `cmux_shim_tab_window_id`
/// puts every browser in window 1 (the pane's), `cmux_shim_fork_api_version` reports API 27 (unplaced
/// tabs wait for the fork's insertion); every other function does nothing and returns 0.
private nonisolated enum AdoptionShim {
    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let windowID: @convention(c) (Int32) -> Int32 = { _ in 1 }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_window_id": unsafeBitCast(windowID, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
