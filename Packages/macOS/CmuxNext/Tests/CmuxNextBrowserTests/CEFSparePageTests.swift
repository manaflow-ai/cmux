import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// HOT PATH AUDIT (browser): a new Chromium tab paid a synchronous `cmux_shim_tab_add` on the main
/// thread (Chromium's UI thread): `cef.tab_add` p50 12.5 ms, p95 14-15 ms (fleet job b1bf9573,
/// new_browser at 2 and 60 workspaces), 99 % of it Chromium's, before the page's first frame. So the
/// page is made ahead, as Chrome on Android's WarmupManager makes a spare WebContents outside the
/// tab model: one Chromium browser in the hidden spare window, made at an idle moment
/// (`CEFSpareWindow.prepare`), that belongs to no tab until a new tab takes it. A tab that takes it
/// makes no `tab_add` in its creation; the next one is made at the next idle moment, never in the
/// creation's turn.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFSparePageTests {
    /// A link opens a tab in a pane whose Chromium window is live: the tab takes the spare page,
    /// which moves into the pane's window, joins as Chromium's active tab once, shows in layer
    /// hosting and loads the tab's address as its first navigation. No `tab_add`.
    @Test func aNewTabInALivePaneTakesTheSparePageWithNoTabAdd() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        let (host, _, container) = try Self.liveHost(runtime)
        let page = try Self.spareWithPage(runtime)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        link.load(Self.address)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()

        #expect(SpareSpy.added.isEmpty, "no tab_add in the new tab's creation")
        #expect(link.browserID == page, "the tab's browser is the spare page")
        #expect(runtime.tabsByBrowser[page] === link)
        #expect(SpareSpy.moved.map(\.browser) == [page], "the spare page moves into the pane's window")
        #expect(SpareSpy.moved.map(\.anchor) == [10])
        #expect(SpareSpy.activated == [page], "made Chromium's active tab once")
        #expect(host.lastActivated == page, "its activation echo is this host's own")
        #expect(host.hostView.layerHosting.browser == page, "layer hosting follows the shown page")
        #expect(SpareSpy.loads.map(\.browser) == [page])
        #expect(SpareSpy.loads.map(\.url) == [Self.address.absoluteString], "the tab's address is the page's first navigation")
    }

    /// The pane's first Chromium tab takes the spare window (`CEFSpareWindow.take`): it takes the
    /// spare page already in that window. Nothing moves, no `tab_add`, no window is built.
    @Test func aTabInAPaneThatTookTheSpareWindowTakesItsSparePage() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        let page = try Self.spareWithPage(runtime)

        let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default)
        let host = runtime.host(for: key)
        #expect(host.key == key && host.isLive, "the pane took the live spare window")
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.load(Self.address)
        host.add(tab)
        host.present(tab, in: container)
        host.createDeferred()

        #expect(SpareSpy.added.isEmpty, "no tab_add in the new tab's creation")
        #expect(SpareSpy.createWindowCalls == 0, "no window is built")
        #expect(tab.browserID == page, "the tab's browser is the spare page")
        #expect(SpareSpy.moved.isEmpty, "the page is already in the window the pane took")
        #expect(SpareSpy.activated == [page], "made Chromium's active tab once")
        #expect(host.lastActivated == page)
        #expect(host.hostView.layerHosting.browser == page)
        #expect(SpareSpy.loads.map(\.url) == [Self.address.absoluteString])
        #expect(host.tabs.filter { $0 !== host.placeholder }.map(\.browserID) == [page], "the spare page is no tab of its own")
    }

    /// The take asks for the next spare page, and the next idle moment makes it in the spare
    /// window; the creation's own turn makes none. At most one untaken spare page.
    @Test func theNextSparePageIsMadeAtTheNextIdleMomentNotInTheCreation() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        let (host, _, container) = try Self.liveHost(runtime)
        let page = try Self.spareWithPage(runtime)
        let needed = Count()
        CEFSpareWindow.shared.onNeeded = { needed.value += 1 }

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()

        #expect(link.browserID == page)
        #expect(needed.value == 1, "the take asks for the next spare page")
        #expect(SpareSpy.added.isEmpty, "the next spare page is not made in the creation's turn")

        // The warmup's next idle moment (`ChromiumWarmup` runs `CEFEngine.prepareSpareWindow`).
        CEFSpareWindow.shared.prepare(runtime: runtime)
        #expect(SpareSpy.added.map(\.anchor) == [20], "made in the spare window")
        #expect(SpareSpy.added.map(\.activate) == [0])
        let next = SpareSpy.added.first?.browser ?? -1
        #expect(next != page && runtime.tabsByBrowser[next] == nil, "a new page that belongs to no tab")
        CEFSpareWindow.shared.prepare(runtime: runtime)
        #expect(SpareSpy.added.count == 1, "at most one untaken spare page")
    }

    /// A tab that restores its history needs a browser with no committed entries of its own:
    /// it keeps today's `tab_add`, and the spare page waits for the next tab.
    @Test func aRestoringTabMakesItsOwnBrowserAndLeavesTheSparePage() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        let (host, _, container) = try Self.liveHost(runtime)
        let page = try Self.spareWithPage(runtime)

        let restored = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        restored.pendingRestore = "saved-navigation"
        host.add(restored)
        host.present(restored, in: container)
        host.createDeferred()

        #expect(SpareSpy.added.map(\.anchor) == [10], "joins the pane's window with tab_add")
        #expect(SpareSpy.added.map(\.url) == [""], "created empty for its restore")
        #expect(restored.browserID != page)
        #expect(SpareSpy.moved.isEmpty)
        #expect(runtime.tabsByBrowser[page] == nil, "the spare page waits for the next tab")
    }

    /// The waiting spare page is frozen as soon as it is made (no one sees it, so it must cost no
    /// frames or timers): through the renderer path on fork API 29, through DevTools when that path
    /// refuses it or the fork is older. A tab that takes it thaws it in the same turn, before it
    /// moves and shows, by the path that froze it.
    @Test(arguments: [FreezeCase(forkAPI: 27, rendererFreezes: true, viaDevTools: true),
                      FreezeCase(forkAPI: 29, rendererFreezes: true, viaDevTools: false),
                      FreezeCase(forkAPI: 29, rendererFreezes: false, viaDevTools: true)])
    func theWaitingSparePageIsFrozenAndATakeThawsItBeforeItShows(_ freeze: FreezeCase) throws {
        let (runtime, root) = try Self.runtime(forkAPI: freeze.forkAPI)
        defer { Self.tearDown(runtime, root) }
        let (host, _, container) = try Self.liveHost(runtime)
        SpareSpy.setFrozenAnswer = freeze.rendererFreezes ? 1 : 0
        let suffix = freeze.viaDevTools ? " devtools" : ""
        SpareSpy.clearRecords()
        #expect(CEFSpareWindow.shared.prepare(runtime: runtime))
        let spare = try #require(CEFSpareWindow.shared.host)
        let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
        SpareSpy.windows[20] = 2
        runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
        SpareSpy.log = []
        CEFSpareWindow.shared.prepare(runtime: runtime)
        let page = try #require(SpareSpy.added.first?.browser)
        #expect(SpareSpy.log == ["freeze \(page)\(suffix)"], "the waiting page is frozen when it is made")

        SpareSpy.log = []
        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        link.load(Self.address)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()

        #expect(link.browserID == page)
        #expect(SpareSpy.log == ["thaw \(page)\(suffix)", "move \(page)", "activate \(page)", "load \(page)"],
                "thawed, then moved, shown and loaded in the take's turn")
        #expect(host.hostView.layerHosting.browser == page, "shown in the same turn")
    }

    /// Only a tab the person sees takes the spare page. A tab made hidden (an agent drives a
    /// background tab, `CEFAgentRelay.createBrowser`) and an agent-driven tab use `tab_add`, so
    /// automation never uses up the page that makes the person's next Cmd-T fast; that tab takes it.
    @Test func aHiddenOrAgentDrivenTabLeavesTheSparePageForThePersonsNextTab() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        let (host, _, container) = try Self.liveHost(runtime)
        let page = try Self.spareWithPage(runtime)

        let background = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(background)
        background.agentRelay.createBrowser()
        #expect(SpareSpy.added.map(\.anchor) == [10], "a hidden tab joins with tab_add")
        #expect(background.browserID != page)

        let agent = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        agent.isAgentDriven = true
        host.add(agent)
        host.present(agent, in: container)
        host.createDeferred()
        #expect(SpareSpy.added.map(\.anchor) == [10, 10], "an agent-driven tab joins with tab_add")
        #expect(agent.browserID != page)
        #expect(runtime.tabsByBrowser[page] == nil, "the spare page still waits")

        let person = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(person)
        host.present(person, in: container)
        host.createDeferred()
        #expect(person.browserID == page, "the person's tab takes it")
        #expect(SpareSpy.added.count == 2, "with no tab_add")
    }

    /// The fork has no way to keep the spare page out of `chrome.tabs` and `chrome.windows`, so an
    /// extension can close it while it waits. The slot clears and asks for a new page; the next
    /// Cmd-T, before that page is made, joins with `tab_add` as it did before the spare page.
    @Test func anExtensionClosingTheWaitingPageClearsTheSlotAndTheNextTabFallsBack() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        let (host, _, container) = try Self.liveHost(runtime)
        let page = try Self.spareWithPage(runtime)
        let needed = Count()
        CEFSpareWindow.shared.onNeeded = { needed.value += 1 }

        runtime.handle(.beforeClose(browser: page))
        #expect(CEFSpareWindow.shared.page == nil, "the slot clears")
        #expect(needed.value == 1, "the next idle moment makes a new page")

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()
        #expect(SpareSpy.added.map(\.anchor) == [10], "joins with tab_add")
        #expect(SpareSpy.added.map(\.activate) == [1])
        #expect(link.browserID == SpareSpy.added.first?.browser && link.browserID != page)
        #expect(SpareSpy.moved.isEmpty && SpareSpy.closed.isEmpty, "nothing touches the closed page")
        #expect(host.lastActivated == link.browserID)
    }

    /// Quit closes every browser (`closeAll`), the waiting spare page among them: its close must not
    /// ask for a new page, which would arm the warmup's idle wait and timers in a quitting app
    /// (review of #34252, finding 1). The same close before quit does ask.
    @Test func theSparePageClosingAtQuitAsksForNoNewPage() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        _ = try Self.liveHost(runtime)
        let page = try Self.spareWithPage(runtime)
        let needed = Count()
        CEFSpareWindow.shared.onNeeded = { needed.value += 1 }

        runtime.state = .shutDown
        runtime.handle(.beforeClose(browser: page))
        #expect(CEFSpareWindow.shared.page == nil, "the slot clears")
        #expect(needed.value == 0, "a quitting app asks for no new spare page")
    }

    /// Only the spare page's own OnAfterCreated is kept from adoption: a tab Chromium makes itself in
    /// the spare window inside that `tab_add` (an extension's) still waits there for the first tab that
    /// takes the window (`CEFSpareWindow.park`), as before (review of #34252, finding 3).
    @Test func aChromiumTabMadeInsideTheSparePagesTabAddIsStillParked() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        #expect(CEFSpareWindow.shared.prepare(runtime: runtime))
        let spare = try #require(CEFSpareWindow.shared.host)
        let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
        SpareSpy.windows[20] = 2
        runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
        SpareSpy.clearRecords()

        SpareSpy.chromiumTabInNextAdd = 77
        CEFSpareWindow.shared.prepare(runtime: runtime)
        let page = try #require(SpareSpy.added.first?.browser)
        #expect(CEFSpareWindow.shared.page?.browser == page)
        #expect(CEFSpareWindow.shared.takeParked().map(\.browser) == [77], "Chromium's own tab is parked for the take")
    }

    /// The fork could not move the spare page into the pane's window: the page closes (no page
    /// lingers in the spare window as a tab nobody owns), and the tab joins with `tab_add`.
    @Test func aSparePageThatCannotMoveClosesAndTheTabFallsBackToTabAdd() throws {
        let (runtime, root) = try Self.runtime()
        defer { Self.tearDown(runtime, root) }
        let (host, _, container) = try Self.liveHost(runtime)
        let page = try Self.spareWithPage(runtime)
        SpareSpy.moveAnswer = 0

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()

        #expect(SpareSpy.moved.map(\.browser) == [page], "it tried to move the page")
        #expect(SpareSpy.closed == [page], "the page that could not move closes")
        #expect(SpareSpy.added.map(\.anchor) == [10] && SpareSpy.added.map(\.activate) == [1], "the tab joins with tab_add")
        #expect(link.browserID == SpareSpy.added.first?.browser && link.browserID != page)
        #expect(host.lastActivated == link.browserID)
        #expect(CEFSpareWindow.shared.page == nil)
    }

    // MARK: Fixture

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
    private static func runtime(forkAPI: Int32 = 27) throws -> (CEFRuntime, URL) {
        SpareSpy.reset(forkAPI: forkAPI)
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-spare-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try SpareSpy.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        SpareSpy.runtime = runtime
        CEFSpareWindow.shared.drop(runtime: runtime)
        CEFSpareWindow.shared.onNeeded = nil
        return (runtime, root)
    }

    private static func tearDown(_ runtime: CEFRuntime, _ root: URL) {
        CEFSpareWindow.shared.drop(runtime: runtime)
        CEFSpareWindow.shared.onNeeded = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A pane showing a Chromium page in its live window (browser 10, window 1).
    private static func liveHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSView) {
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
    private static func spareWithPage(_ runtime: CEFRuntime) throws -> Int32 {
        #expect(CEFSpareWindow.shared.prepare(runtime: runtime), "the spare window starts")
        let spare = try #require(CEFSpareWindow.shared.host)
        let request = try #require(runtime.pendingWindows.first { $0.value === spare }?.key)
        SpareSpy.windows[20] = 2
        runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
        #expect(spare.isLive && spare.placeholder?.browserID == 20)
        SpareSpy.clearRecords()

        CEFSpareWindow.shared.prepare(runtime: runtime)
        #expect(SpareSpy.added.map(\.anchor) == [20], "the next idle moment makes the spare page in the spare window")
        #expect(SpareSpy.added.map(\.activate) == [0], "in the background")
        #expect(SpareSpy.added.map(\.url) == [""], "with an empty URL: no blank history entry")
        let page = SpareSpy.added.first?.browser ?? -1
        #expect(runtime.tabsByBrowser[page] == nil, "the spare page belongs to no tab")
        #expect(CEFSpareWindow.shared.takeParked().isEmpty, "its OnAfterCreated is no Chromium tab to adopt")
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
private nonisolated enum SpareSpy {
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
