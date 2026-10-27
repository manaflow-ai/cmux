import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Crash on quit, NIGHTLY 1.0.0-nightly.3953614980201 (2026-10-20): AppKit closed the windows
/// for termination after CefShutdown, a window's observer removed a view, a hidden Chromium tab's
/// content view lost its hidden ancestor (`viewDidUnhide`), and the pane created its browser
/// (`cmux_shim_create_window`): CEF aborts creating a browser after shutdown began.
@MainActor @Suite(.serialized) struct CEFQuitCreationTests {
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

        #expect(SpyShim.calls == ["close 7", "shutdown"])
        #expect(runtime.state == .shutDown)
    }

    /// A creation Chromium never finishes holds quit only until its wait runs out: quit ends,
    /// without CefShutdown, as a wait that runs out did before.
    @Test func aCreationChromiumNeverFinishesHoldsQuitOnlyUntilTheTimeout() async throws {
        SpyShim.reset()
        SpyShim.createOpensWindow = false
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.startCreation(runtime)

        await runtime.shutdown(timeout: .milliseconds(200))

        #expect(SpyShim.calls.isEmpty)
        #expect(runtime.state == .shutDown)
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
/// it yet); `cmux_shim_window_count` reports the open windows, `cmux_shim_close` and
/// `cmux_shim_shutdown` record their calls (`calls` in order); every other function does nothing
/// and returns 0.
private nonisolated enum SpyShim {
    nonisolated(unsafe) static var createWindowCalls = 0
    nonisolated(unsafe) static var windows: Int32 = 0
    nonisolated(unsafe) static var closed: [Int32] = []
    nonisolated(unsafe) static var shutdowns = 0
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var createOpensWindow = true

    static func reset() {
        createWindowCalls = 0
        windows = 0
        closed = []
        shutdowns = 0
        calls = []
        createOpensWindow = true
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
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_window_count": unsafeBitCast(windowCount, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_shutdown": unsafeBitCast(shutdown, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
