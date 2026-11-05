import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// The spare page suites' one parent. Their tests share the stand-in shim's statics (`SpareSpy`) and the
/// `browserPage.sparePage` switch in `TunableStore.shared`, and `.serialized` orders only the tests under one
/// suite: under this parent every test of both runs one at a time, in one process too. Each test has its own
/// `CEFRuntime`, so its spare window and page (`runtime.spareWindow`) are no other suite's. Windows are checked
/// once, here at the top level (`.closesItsWindows`).
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFSparePageSuites {}

/// The stand-in shim and helpers shared by `CEFSparePageTests` and `CEFSparePageCloseTests`.
extension CEFSparePageSuites.CEFSparePageTests {
    static let address = URL(string: "https://example.com/")!

    final class Count { var value = 0 }

    /// A fork, whether its renderer-path freeze takes the page, and the path the page is frozen by.
    struct FreezeCase: Sendable, CustomTestStringConvertible {
        var forkAPI: Int32
        var rendererFreezes: Bool
        var viaDevTools: Bool
        var testDescription: String { "fork API \(forkAPI), renderer freeze \(rendererFreezes ? "takes" : "refuses")" }
    }

    /// A runtime that outlives the test (as in `CEFDeferredTabShowTests`), and no spare left by another test.
    static func runtime(forkAPI: Int32 = 27) throws -> (CEFRuntime, URL) {
        SpareSpy.reset(forkAPI: forkAPI)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-spare-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try SpareSpy.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        SpareSpy.runtime = runtime
        setSparePage(true)
        return (runtime, root)
    }

    /// Ends a test: the main-actor work it left runs now, while its runtime and the shim's records are still this
    /// test's (a taken spare window's `closeSparePlaceholder` Task, which the main queue runs, and a `giveBack`
    /// close, a `CFRunLoopPerformBlock` in the common modes). Each run-loop pass with a deadline in the past
    /// services the main queue and the performed blocks once and waits for nothing; a block one of them queues
    /// runs in the next pass. Then the spare closes and the switch goes back to its default.
    static func tearDown(_ runtime: CEFRuntime, _ root: URL) {
        for _ in 0..<8 { RunLoop.main.run(mode: .default, before: .distantPast) }
        runtime.spareWindow.drop(runtime: runtime)
        runtime.spareWindow.onNeeded = nil
        setSparePage(nil)
        try? FileManager.default.removeItem(at: root)
    }

    /// Debug Settings `browserPage.sparePage` (nil: the default, off).
    static func setSparePage(_ on: Bool?) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([CEFSpareWindow.pageSetting.descriptor])
        TunableStore.shared.set(CEFSpareWindow.pageSetting.key, on.map { .bool($0) })
        #expect(CEFSpareWindow.pageSetting.value == on ?? false)
    }

    /// A pane showing a Chromium page in its live window (browser 10, window 1).
    static func liveHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSView) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        SpareSpy.windows[10] = 1
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        #expect(host.isLive && first.browserID == 10)
        return (host, first, container)
    }

    /// The warmup's idle moments: the spare window (placeholder browser 20, window 2), then the
    /// spare page in it. Returns the spare page's browser (-1 when none was made); the spy's
    /// records start empty after it.
    static func spareWithPage(_ runtime: CEFRuntime) throws -> Int32 {
        #expect(runtime.spareWindow.prepare(runtime: runtime), "the spare window starts")
        let spare = try #require(runtime.spareWindow.host)
        let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
        SpareSpy.windows[20] = 2
        runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
        #expect(spare.isLive && spare.placeholder?.browserID == 20)
        SpareSpy.clearRecords()

        runtime.spareWindow.prepare(runtime: runtime)
        #expect(SpareSpy.added.map(\.anchor) == [20], "the next idle moment makes the spare page in the spare window")
        #expect(SpareSpy.added.map(\.activate) == [0], "in the background")
        #expect(SpareSpy.added.map(\.url) == [""], "with an empty URL: no blank history entry")
        let page = SpareSpy.added.first?.browser ?? -1
        #expect(runtime.tabsByBrowser[page] == nil, "the spare page belongs to no tab")
        #expect(runtime.spareWindow.takeParked().isEmpty, "its OnAfterCreated is no Chromium tab to adopt")
        SpareSpy.clearRecords()
        return page
    }
}

/// Stand-in shim functions. `cmux_shim_tab_add` gives a new browser (30, 31, ...) in its anchor's
/// window and, as production's shim does, runs its OnAfterCreated before it returns;
/// `cmux_shim_tab_move_to_window` moves a browser into its anchor's window; `cmux_shim_tab_window_id`
/// reads those windows; `cmux_shim_tab_activate`, `cmux_shim_close`, `cmux_shim_load_url` and
/// `cmux_shim_create_window` are recorded; `cmux_shim_tab_set_frozen` and DevTools
/// `Page.setWebLifecycleState` (`cmux_shim_devtools_call`) are logged as freezes and thaws;
/// `cmux_shim_fork_api_version` is `forkAPI` (27 by default: layer hosting, no renderer paths);
/// every other function does nothing and returns 0.
nonisolated enum SpareSpy {
    nonisolated(unsafe) static var added: [(anchor: Int32, url: String, activate: Int32, browser: Int32)] = []
    nonisolated(unsafe) static var moved: [(browser: Int32, anchor: Int32)] = []
    nonisolated(unsafe) static var activated: [Int32] = []
    nonisolated(unsafe) static var closed: [Int32] = []
    nonisolated(unsafe) static var loads: [(browser: Int32, url: String)] = []
    nonisolated(unsafe) static var createWindowCalls = 0
    nonisolated(unsafe) static var windows: [Int32: Int32] = [:]
    nonisolated(unsafe) static var nextBrowser: Int32 = 30
    /// Every page-state call in order: `freeze <b>`, `thaw <b>` (either freeze path), `move <b>`, `activate <b>`, `load <b>`.
    nonisolated(unsafe) static var log: [String] = []
    /// What `cmux_shim_tab_set_frozen` answers (1: the renderer-path freeze took the page).
    nonisolated(unsafe) static var setFrozenAnswer: Int32 = 1
    nonisolated(unsafe) static var forkAPI: Int32 = 27
    /// What `cmux_shim_tab_move_to_window` answers (0: the fork could not move the tab).
    nonisolated(unsafe) static var moveAnswer: Int32 = 1
    /// The next `cmux_shim_tab_add` also gets OnAfterCreated for one browser Chromium makes itself
    /// in the same window (an extension's tab) before the added tab's: that browser's id.
    nonisolated(unsafe) static var chromiumTabInNextAdd: Int32?
    nonisolated(unsafe) static weak var runtime: CEFRuntime?

    static func reset(forkAPI: Int32 = 27) {
        clearRecords()
        windows = [:]
        nextBrowser = 30
        setFrozenAnswer = 1
        moveAnswer = 1
        chromiumTabInNextAdd = nil
        self.forkAPI = forkAPI
        runtime = nil
    }

    static func clearRecords() {
        added = []
        moved = []
        activated = []
        closed = []
        loads = []
        log = []
        createWindowCalls = 0
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            SpareSpy.createWindowCalls += 1
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, url, _, activate in
            let browser = SpareSpy.nextBrowser
            SpareSpy.nextBrowser += 1
            let window = SpareSpy.windows[anchor] ?? 0
            SpareSpy.windows[browser] = window
            SpareSpy.added.append((anchor, url.map { String(cString: $0) } ?? "", activate, browser))
            let other = SpareSpy.chromiumTabInNextAdd
            SpareSpy.chromiumTabInNextAdd = nil
            if let other { SpareSpy.windows[other] = window }
            MainActor.assumeIsolated {
                if let other { SpareSpy.runtime?.handle(.afterCreated(browser: other, request: 0, window: window)) }
                SpareSpy.runtime?.handle(.afterCreated(browser: browser, request: 0, window: window))
            }
            return browser
        }
        let tabMove: @convention(c) (Int32, Int32, Int32) -> Int32 = { browser, anchor, _ in
            SpareSpy.moved.append((browser, anchor))
            SpareSpy.log.append("move \(browser)")
            guard SpareSpy.moveAnswer == 1 else { return 0 }
            SpareSpy.windows[browser] = SpareSpy.windows[anchor] ?? 0
            return 1
        }
        let tabWindowID: @convention(c) (Int32) -> Int32 = { browser in SpareSpy.windows[browser] ?? 0 }
        let tabActivate: @convention(c) (Int32) -> Int32 = { browser in
            SpareSpy.activated.append(browser)
            SpareSpy.log.append("activate \(browser)")
            return 1
        }
        let close: @convention(c) (Int32) -> Void = { browser in SpareSpy.closed.append(browser) }
        let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { browser, url in
            SpareSpy.loads.append((browser, url.map { String(cString: $0) } ?? ""))
            SpareSpy.log.append("load \(browser)")
        }
        let setFrozen: @convention(c) (Int32, Int32) -> Int32 = { browser, frozen in
            guard SpareSpy.setFrozenAnswer == 1 else { return 0 }
            SpareSpy.log.append("\(frozen == 1 ? "freeze" : "thaw") \(browser)")
            return 1
        }
        let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { browser, method, params in
            let text = params.map { String(cString: $0) } ?? ""
            if method.map({ String(cString: $0) }) == "Page.setWebLifecycleState" {
                SpareSpy.log.append("\(text.contains("frozen") ? "freeze" : "thaw") \(browser) devtools")
            }
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { SpareSpy.forkAPI }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_move_to_window": unsafeBitCast(tabMove, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_window_id": unsafeBitCast(tabWindowID, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_activate": unsafeBitCast(tabActivate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_load_url": unsafeBitCast(loadURL, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_set_frozen": unsafeBitCast(setFrozen, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_devtools_call": unsafeBitCast(devToolsCall, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
