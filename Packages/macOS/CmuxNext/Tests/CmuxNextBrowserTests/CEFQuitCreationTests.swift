import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Crash on quit, NIGHTLY 1.0.0-nightly.3953614980201 (2026-10-20): AppKit closed the windows
/// for termination after CefShutdown, a window's observer removed a view, a hidden Chromium tab's
/// content view lost its hidden ancestor (`viewDidUnhide`), and the pane created its browser
/// (`cmux_shim_create_window`): CEF aborts creating a browser after shutdown began.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFQuitCreationTests {
    @Test func noBrowserIsMadeOnceChromiumBeganToStop() {
        #expect(CEFRuntime.acceptsNewBrowsers(state: .ready, stopping: false))
        // Quit closed every browser and waits for Chromium to destroy them (`shutdown`).
        #expect(!CEFRuntime.acceptsNewBrowsers(state: .ready, stopping: true))
        // CefShutdown ran, or quit came while the library was still loading.
        #expect(!CEFRuntime.acceptsNewBrowsers(state: .shutDown, stopping: false))
    }

    /// The crash's path, against a spy shim: a parked tab never shown unhides in its window
    /// (`viewDidUnhide`), so the tab appears and its pane makes its browser
    /// (`CEFTab.contentDidAppear`, `CEFPaneHost.present`, `ensureCreated`).
    @Test func aParkedTabUnhiddenAfterChromiumStoppedMakesNoBrowser() throws {
        SpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-quit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try SpyShim.library(), storage: CEFProfileStorage(root: root))
        // Chromium running: the tab gets its browser.
        #expect(try unhideParkedTab(runtime) == 1)
        runtime.state = .shutDown
        #expect(try unhideParkedTab(runtime) == 0)
    }

    /// PL-cef-tab: showing a tab whose browser does not exist must not build its Chromium window
    /// in that turn (CefBrowserHost::CreateBrowser holds the main thread for 80 ms to 0.8 s), so
    /// the tab's toolbar and themed page area draw in the frame of the key that asked for it. The
    /// browser follows after the frame commits, once per tab.
    @Test func showingATabWithoutABrowserMakesItAfterTheTurnsFrame() throws {
        SpyShim.reset()
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.present(tab, in: container)
        #expect(SpyShim.createWindowCalls == 0, "the turn that shows the tab builds no Chromium window")
        host.present(tab, in: container)
        host.createDeferred()
        #expect(SpyShim.createWindowCalls == 1, "built once, after the frame")
    }

    /// A browser whose creation was under way when quit closed every browser: Chromium makes it
    /// after `cmux_shim_close_all`. Quit closes it too, so the wait for Chromium's windows ends and
    /// CefShutdown runs; it used to stay open until the wait ran out and CefShutdown was skipped.
    @Test func aBrowserMadeAfterQuitClosedEveryBrowserIsClosedToo() async throws {
        SpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-quit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try SpyShim.library(), storage: CEFProfileStorage(root: root))
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)

        let quit = Task { await runtime.shutdown(timeout: .seconds(2)) }
        for _ in 0..<100 where runtime.shutdownSequence == nil { await Task.yield() }
        #expect(runtime.shutdownSequence != nil)
        let created = ContinuousClock.now
        runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
        // Chromium destroys a browser (and its window) only when asked to close it.
        if SpyShim.closed.contains(7) {
            SpyShim.windows = 0
            runtime.handle(.beforeClose(browser: 7))
        }
        await quit.value

        #expect(SpyShim.closed == [7])
        #expect(SpyShim.shutdowns == 1, "CefShutdown ran: the wait did not run out")
        #expect(ContinuousClock.now - created < .seconds(1))
        #expect(runtime.state == .shutDown)
    }

    /// A creation under way whose Chromium window does not exist yet: no window is open, so the
    /// window count was 0 at once and quit called CefShutdown under the creation (SIGSEGV in
    /// CefShutdown live). Quit now waits for every pending window too, closes the browser when
    /// Chromium makes it, and shuts down once that browser's window is gone too.
    @Test func aCreationWithNoWindowYetHoldsCefShutdownUntilItsBrowserCloses() async throws {
        SpyShim.reset()
        SpyShim.createOpensWindow = false
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try Self.startCreation(runtime)

        let quit = Task { await runtime.shutdown(timeout: .seconds(5)) }
        for _ in 0..<100 where runtime.shutdownSequence == nil { await Task.yield() }
        #expect(runtime.shutdownSequence != nil, "quit began")
        // Chromium made the browser and its window; the fork counts the window until the Browser's
        // destructor, after BEFORE_CLOSE (browser.md, fork clip patches).
        SpyShim.windows = 1
        runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
        if SpyShim.closed.contains(7) { runtime.handle(.beforeClose(browser: 7)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(SpyShim.calls == ["close 7"], "CefShutdown ran while the late browser's window was open")
        SpyShim.windows = 0
        runtime.handle(.tab(.windowDestroyed, browser: 7, window: 1, value: 0))
        await quit.value

        #expect(SpyShim.calls == ["close 7", "flush", "shutdown"])
        #expect(runtime.state == .shutDown)
    }

    /// A creation Chromium never finishes holds quit only until its wait runs out: quit ends,
    /// without CefShutdown, as a wait that runs out did before, and still commits the cookies.
    @Test func aCreationChromiumNeverFinishesHoldsQuitOnlyUntilTheTimeout() async throws {
        SpyShim.reset()
        SpyShim.createOpensWindow = false
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.startCreation(runtime)

        await runtime.shutdown(timeout: .milliseconds(200))

        #expect(SpyShim.calls == ["flush"])
        #expect(runtime.state == .shutDown)
    }

    /// cmuxterm-hq#6338: CefShutdown held the main thread 2 to 3.4 s at quit (8 of the nightly's hang files,
    /// 7 still blocked when the quit deadline ended the process inside it, before Chromium's own cookie
    /// flush finished). Quit now commits every cookie store first, with the main thread free (the spy's
    /// commit takes `SpyShim.commitCost` on another thread), so CefShutdown has no cookie write left (the
    /// spy's CefShutdown does an uncommitted store's write on the main thread, as Chromium's does).
    @Test func quitCommitsTheCookieStoresWithTheMainThreadFreeBeforeCefShutdown() async throws {
        SpyShim.reset()
        SpyShim.hasUncommittedStores = true
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        SpyShim.answerFlush = Self.answerAfterCommit(runtime)

        let blocked = await Self.longestMainThreadBlock { await runtime.shutdown(timeout: .seconds(2)) }

        print("CEFQuitCookieFlush: longest main-thread block during quit \(blocked) (spy commit \(SpyShim.commitCost))")
        #expect(SpyShim.calls == ["flush", "shutdown"], "the cookie stores were not committed before CefShutdown")
        #expect(SpyShim.storesCommitted, "the cookie stores reached disk")
        #expect(blocked < .milliseconds(200), "quit held the main thread \(blocked) for the cookie write")
        #expect(runtime.state == .shutDown)
    }

    /// The same harness with a shim that cannot flush (returns 0, as at base, where quit asked for no flush):
    /// CefShutdown does the write on the main thread. Keeps the measurement honest: the spy's cost shows.
    @Test func withNoFlushCefShutdownWritesTheCookiesOnTheMainThread() async throws {
        SpyShim.reset()
        SpyShim.hasUncommittedStores = true
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }

        let blocked = await Self.longestMainThreadBlock { await runtime.shutdown(timeout: .seconds(2)) }

        print("CEFQuitCookieFlush: no flush, longest main-thread block during quit \(blocked) (spy commit \(SpyShim.commitCost))")
        #expect(blocked >= SpyShim.commitCost)
        #expect(SpyShim.storesCommitted)
    }

    /// A flush Chromium never answers holds quit for at most its limit, and CefShutdown still runs.
    @Test func aCookieFlushChromiumNeverAnswersHoldsQuitOnlyItsLimit() async throws {
        SpyShim.reset()
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        SpyShim.answerFlush = { _ in }

        let started = ContinuousClock.now
        await runtime.shutdown(timeout: .seconds(2))
        let took = ContinuousClock.now - started

        #expect(SpyShim.calls == ["flush", "shutdown"])
        #expect(took < .seconds(2), "quit waited \(took) on a flush that never answered")
        #expect(runtime.state == .shutDown)
    }

    /// The App hides its windows (`beforeEngineStop`) right before CefShutdown blocks the main thread, so a
    /// decided quit looks done instead of a frozen window; a quit that skips CefShutdown hides nothing.
    @Test func theWindowsGoRightBeforeCefShutdownBlocksTheMainThread() async throws {
        SpyShim.reset()
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        SpyShim.answerFlush = Self.answerAfterCommit(runtime)

        await runtime.shutdown(timeout: .seconds(2), beforeEngineStop: { SpyShim.calls.append("hide") })

        #expect(SpyShim.calls == ["flush", "hide", "shutdown"])

        SpyShim.reset()
        SpyShim.createOpensWindow = false
        let (stuck, stuckRoot) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: stuckRoot) }
        _ = try Self.startCreation(stuck)
        await stuck.shutdown(timeout: .milliseconds(200), beforeEngineStop: { SpyShim.calls.append("hide") })
        #expect(SpyShim.calls == ["flush"], "a quit that skips CefShutdown hid the windows")
    }

    /// The spy's flush answer: the commit runs on another thread for `commitCost`, then Chromium's REPLY
    /// reaches the runtime on the main thread.
    private static func answerAfterCommit(_ runtime: CEFRuntime) -> @Sendable (Int32) -> Void {
        { id in
            DispatchQueue.global().asyncAfter(deadline: .now() + SpyShim.commitSeconds) {
                SpyShim.storesCommitted = true
                Task { @MainActor in runtime.handle(.reply(browser: 0, id: id, value: 1, json: "[]")) }
            }
        }
    }

    /// The longest the main thread went without running a 2 ms heartbeat while `body` ran.
    private static func longestMainThreadBlock(_ body: () async -> Void) async -> Duration {
        let beat = Heartbeat()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                beat.tick()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        await Task.yield()
        await body()
        beat.tick()
        ticker.cancel()
        return beat.longest
    }

    @MainActor private final class Heartbeat {
        private var last = ContinuousClock.now
        private(set) var longest: Duration = .zero
        func tick() {
            let now = ContinuousClock.now
            longest = max(longest, now - last)
            last = now
        }
    }

    private static func spyRuntime() throws -> (CEFRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-quit-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (CEFRuntime(shim: try SpyShim.library(), storage: CEFProfileStorage(root: root)), root)
    }

    /// A new pane's tab whose browser is being made: its pending window's request.
    private static func startCreation(_ runtime: CEFRuntime) throws -> Int32 {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        return try #require(runtime.pendingWindows.keys.first)
    }

    /// Calls of `cmux_shim_create_window` while a parked Chromium tab of a new pane unhides.
    private func unhideParkedTab(_ runtime: CEFRuntime) throws -> Int {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        let parked = NSView(frame: content.bounds)
        parked.isHidden = true
        content.addSubview(parked)
        parked.addSubview(tab.contentView)
        let before = SpyShim.createWindowCalls
        parked.isHidden = false
        // The browser is made once the turn's frame committed (`CEFPaneHost.createAfterCommit`).
        #expect(SpyShim.createWindowCalls == before, "no browser in the turn that shows the tab")
        host.createDeferred()
        return SpyShim.createWindowCalls - before
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` counts its calls, reports the browser
/// started and opens its Chromium window (unless `createOpensWindow` is off: Chromium has not made
/// it yet); `cmux_shim_window_count` reports the open windows, `cmux_shim_close`,
/// `cmux_shim_flush_cookie_stores` and `cmux_shim_shutdown` record their calls (`calls` in order).
/// The flush starts (1) only when `answerFlush` is set, which answers it; with
/// `hasUncommittedStores` the shutdown writes a store not yet committed on the calling (main)
/// thread, for `commitCost`, as CefShutdown does.
/// Every other function does nothing and returns 0.
private nonisolated enum SpyShim {
    nonisolated(unsafe) static var createWindowCalls = 0
    nonisolated(unsafe) static var windows: Int32 = 0
    nonisolated(unsafe) static var closed: [Int32] = []
    nonisolated(unsafe) static var shutdowns = 0
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var createOpensWindow = true
    nonisolated(unsafe) static var answerFlush: (@Sendable (Int32) -> Void)?
    nonisolated(unsafe) static var storesCommitted = false
    /// The spy's profiles hold cookie writes not yet on disk (the cookie flush tests).
    nonisolated(unsafe) static var hasUncommittedStores = false
    static let commitCost: Duration = .milliseconds(300)
    static let commitSeconds = 0.3

    static func reset() {
        createWindowCalls = 0
        windows = 0
        closed = []
        shutdowns = 0
        calls = []
        createOpensWindow = true
        answerFlush = nil
        storesCommitted = false
        hasUncommittedStores = false
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            SpyShim.createWindowCalls += 1
            if SpyShim.createOpensWindow { SpyShim.windows += 1 }
            return 1
        }
        let windowCount: @convention(c) () -> Int32 = { SpyShim.windows }
        let close: @convention(c) (Int32) -> Void = { browser in
            SpyShim.closed.append(browser)
            SpyShim.calls.append("close \(browser)")
        }
        let shutdown: @convention(c) () -> Void = {
            SpyShim.shutdowns += 1
            SpyShim.calls.append("shutdown")
            if SpyShim.hasUncommittedStores, !SpyShim.storesCommitted {
                // concurrency-allow: the spy's CefShutdown writes an uncommitted cookie store on the main thread, as Chromium's does
                Thread.sleep(forTimeInterval: SpyShim.commitSeconds)
                SpyShim.storesCommitted = true
            }
        }
        let flush: @convention(c) (Int32) -> Int32 = { reply in
            SpyShim.calls.append("flush")
            guard let answer = SpyShim.answerFlush else { return 0 }
            answer(reply)
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_window_count": unsafeBitCast(windowCount, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_shutdown": unsafeBitCast(shutdown, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_flush_cookie_stores": unsafeBitCast(flush, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
