@testable import CmuxNextBrowser
import CmuxNextInput
import Foundation
import Testing

/// One spare Chromium window per store kind (the default profile's and the cmux
/// pages profile's). A cmux page's key takes the pages spare instead of building a window on its
/// key's turn (`window_built_on_key_turn` stays 0); an incognito window's or a remote machine's
/// key never takes one; at most one untaken spare per kind; a spare that came up asks for the next
/// missing kind. Driven against a spy shim that counts
/// `cmux_shim_create_window`; each test has its own runtime, so its own spares.
@MainActor @Suite(.serialized) struct CEFSpareWindowKindsTests {
    private let pages = BrowserProfileID(rawValue: UUID())

    @Test func aPageKeyTakesThePagesSpareAndBuildsNoWindow() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        #expect(spares.prepare(.pages, runtime: runtime))
        let spare = try #require(spares.host(of: .pages))
        #expect(spares.state(of: .pages) == .creating)
        #expect(SpareSpyShim.createWindowCalls == 1)

        let host = runtime.host(for: pageKey())
        #expect(host === spare, "the page's key joins the spare's window")
        #expect(host.key == pageKey(pane: host.key.pane), "re-keyed to the page's pane, same store")
        #expect(!host.key.pane.rawValue.hasPrefix(CEFSpareWindow.panePrefix))
        #expect(spares.state(of: .pages) == .taken)

        // The page's tab asks for its browser: it joins the spare's window, none is built for it.
        build(host, runtime: runtime)
        #expect(SpareSpyShim.createWindowCalls == 1, "no window built for the page")
        #expect(spares.windowsBuiltOnKeyTurn == 0)
    }

    /// The case the pages spare removes: with none ready, the page's tab builds a window on its turn.
    @Test func aPageKeyWithNoPagesSpareBuildsAWindowOnItsTurn() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        let host = runtime.host(for: pageKey())
        #expect(!host.key.pane.rawValue.hasPrefix(CEFSpareWindow.panePrefix))

        build(host, runtime: runtime)
        #expect(SpareSpyShim.createWindowCalls == 1, "the page's own window")
        #expect(spares.windowsBuiltOnKeyTurn == 1)
    }

    /// Live spares, so no window is being built: only the per-kind limit refuses a second spare.
    @Test func atMostOneUntakenSparePerKind() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        #expect(spares.prepare(.pages, runtime: runtime))
        try Self.comeUp(runtime, browser: 10)
        #expect(spares.state(of: .pages) == .live)
        #expect(!runtime.hosts.values.contains { $0.isCreatingWindow }, "no window is being built")

        #expect(!spares.prepare(.pages, runtime: runtime), "a second untaken pages spare")
        #expect(SpareSpyShim.createWindowCalls == 1)
        #expect(spares.prepare(.browser, runtime: runtime), "the other kind still gets its spare")
        #expect(SpareSpyShim.createWindowCalls == 2)
        try Self.comeUp(runtime, browser: 11)
        #expect(spares.state(of: .browser) == .live)
        #expect(!spares.prepare(.browser, runtime: runtime), "a second untaken browser spare")
        #expect(!spares.prepare(.pages, runtime: runtime))
        #expect(SpareSpyShim.createWindowCalls == 2)
    }

    @Test func noSpareIsBuiltBesideAWindowBeingBuilt() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        #expect(spares.prepare(.pages, runtime: runtime))
        #expect(spares.state(of: .pages) == .creating)
        #expect(!spares.prepare(.browser, runtime: runtime), "the pages spare's window is still being built")
        #expect(SpareSpyShim.createWindowCalls == 1)
    }

    /// A spare's window came up while another wanted kind has none: it asks for the next spare
    /// (`onNeeded`, the warmup's next idle step). Once every wanted kind has one, a window that
    /// comes up asks for nothing.
    @Test func aSpareThatCameUpAsksForTheNextKindUntilEachHasOne() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        spares.setWantsPages(true, runtime: runtime)
        let asked = Counter()
        spares.onNeeded = { asked.value += 1 }

        #expect(spares.prepareNext(runtime: runtime))
        #expect(spares.state(of: .browser) == .creating)
        try Self.comeUp(runtime, browser: 10)
        #expect(spares.state(of: .browser) == .live)
        #expect(asked.value == 1, "the pages spare is missing")

        #expect(spares.prepareNext(runtime: runtime))
        #expect(spares.state(of: .pages) == .creating)
        try Self.comeUp(runtime, browser: 11)
        #expect(spares.state(of: .pages) == .live)
        #expect(asked.value == 1, "every wanted kind has a spare")
        #expect(!spares.prepareNext(runtime: runtime))
    }

    @Test func incognitoAndRemoteKeysNeverTakeASpare() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        #expect(spares.prepare(.pages, runtime: runtime))
        let spare = try #require(spares.host(of: .pages))

        let incognito = CEFPaneKey(pane: Self.pane(), profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true)
        let remote = CEFPaneKey(pane: Self.pane(), profile: pages, machineKey: "machine-1", offTheRecord: true)
        let remoteDefault = CEFPaneKey(pane: Self.pane(), profile: .default, machineKey: "machine-1")
        let popup = CEFPaneKey(pane: BrowserPaneID(rawValue: CEFPaneHost.popupPrefix + "x"), profile: pages, offTheRecord: true)
        for key in [incognito, remote, remoteDefault, popup] {
            #expect(spares.kind(for: key) == nil)
            #expect(runtime.host(for: key) !== spare)
        }
        #expect(spares.host(of: .pages) === spare, "still the untaken spare")
        #expect(spares.kind(for: pageKey()) == .pages)
        #expect(spares.kind(for: CEFPaneKey(pane: Self.pane(), profile: .default)) == .browser)
        #expect(spares.kind(for: CEFPaneKey(pane: Self.pane(), profile: BrowserProfileID(rawValue: UUID()))) == nil,
                "another persistent profile has no spare")
    }

    /// The counter `debug.cef` reports as `window_built_on_key_turn`: a window built for a key a
    /// spare serves, because none of its kind was ready. Incognito and the spare's own window do
    /// not count.
    @Test func aWindowBuiltForAKeyASpareServesCounts() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        #expect(spares.prepare(.pages, runtime: runtime))
        #expect(spares.windowsBuiltOnKeyTurn == 0, "the spare's own window")

        let incognito = CEFPaneKey(pane: Self.pane(), profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true)
        build(runtime.host(for: incognito), runtime: runtime)
        #expect(spares.windowsBuiltOnKeyTurn == 0, "an incognito window has no spare to miss")

        build(runtime.host(for: CEFPaneKey(pane: Self.pane(), profile: .default)), runtime: runtime)
        #expect(spares.windowsBuiltOnKeyTurn == 1, "the default profile's key found no spare")
    }

    @Test func thePagesSpareIsWantedOnlyWithItsProfileAndTheSwitch() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        #expect(spares.wantedKinds == [.browser])
        spares.setWantsPages(true, runtime: runtime)
        #expect(spares.wantedKinds == [.browser], "no pages profile yet")
        spares.pagesProfile = pages
        #expect(spares.wantedKinds == [.browser, .pages])
        #expect(spares.missingKind == .browser, "the default profile's spare first")
        #expect(spares.prepareNext(runtime: runtime))
        #expect(spares.host(of: .browser) != nil)
        #expect(spares.missingKind == .pages)

        let (other, otherRoot) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        other.spareWindow.pagesProfile = pages
        other.spareWindow.setWantsPages(true, runtime: other)
        #expect(other.spareWindow.prepare(.pages, runtime: other))
        let dropped = try #require(other.spareWindow.host(of: .pages))
        // Pages left Chromium (`CEFEngine.dropPagesSpareWindow`, on a `browser.defaultEngine` switch).
        other.spareWindow.setWantsPages(false, runtime: other)
        #expect(other.spareWindow.host(of: .pages) == nil, "turning it off closes the untaken pages spare")
        #expect(other.spareWindow.state(of: .pages) == .taken, "made once, none untaken")
        #expect(dropped.placeholder == nil)
        #expect(!other.hosts.values.contains { $0 === dropped }, "no host of it is left")
        #expect(other.spareWindow.wantedKinds == [.browser])
    }

    /// A page closed before it joined the window: the window is the pages spare again, keyed as one.
    @Test func aPageClosedBeforeItJoinedGivesThePagesSpareBack() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        spares.setWantsPages(true, runtime: runtime)
        #expect(spares.prepare(.pages, runtime: runtime))
        let host = runtime.host(for: pageKey())
        let page = CEFTab(id: .random(), profile: pages, host: host, runtime: runtime)
        host.add(page)
        host.removed(page)

        #expect(spares.host(of: .pages) === host)
        #expect(host.key.pane.rawValue.hasPrefix(CEFSpareWindow.panePrefix))
        #expect(host.key.profile == pages && host.key.offTheRecord && host.key.machineKey == nil)
        #expect(runtime.hosts[host.key] === host)
    }

    /// Memory pressure holds the spares (`CEFEngine.holdSpareWindows`,
    /// from the warmup's memory consumer): holding keeps the untaken ones (Chrome keeps its spare
    /// renderer at warning), critical closes them (`closeUntakenSpareWindows`), no spare is made, a
    /// taken spare whose tab closed before it joined is not given back, and a window that comes up
    /// asks for none. A tab Chromium parked in a closed spare leaves with it (`CEFOrphanTabs.rehome`):
    /// the next spare of that kind adopts nothing stale. Let go, a spare is made again.
    @Test func heldSparesCloseAndNoneIsMadeOrGivenBackUntilLetGo() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        spares.setWantsPages(true, runtime: runtime)
        let asked = Counter()
        spares.onNeeded = { asked.value += 1 }
        #expect(spares.prepare(.browser, runtime: runtime))
        try Self.comeUp(runtime, browser: 10)
        #expect(spares.prepare(.pages, runtime: runtime))
        try Self.comeUp(runtime, browser: 11)
        let browserSpare = try #require(spares.host(of: .browser))
        // An extension's `chrome.tabs.create` put a tab into the untaken spare's window.
        browserSpare.adoptChromiumTab(browser: 77)
        let taken = runtime.host(for: pageKey())
        let page = CEFTab(id: .random(), profile: pages, host: taken, runtime: runtime)
        taken.add(page)
        let askedBeforeHold = asked.value

        spares.setHeld(true)
        #expect(spares.untakenCount == 1, "holding (warning) closed the untaken browser spare")
        #expect(browserSpare.placeholder != nil)
        spares.drop(runtime: runtime)
        #expect(spares.untakenCount == 0, "critical closes the untaken spares")
        #expect(browserSpare.placeholder == nil)
        #expect(!runtime.hosts.values.contains { $0 === browserSpare })
        #expect(!spares.prepare(.browser, runtime: runtime), "a spare was made while held")
        #expect(!spares.prepareNext(runtime: runtime))

        taken.removed(page)
        #expect(spares.host(of: .pages) == nil, "a held spare was given back")
        spares.windowCameUp(taken)
        #expect(asked.value == askedBeforeHold, "a window that came up asked for a spare while held")

        spares.setHeld(false)
        #expect(spares.prepare(.browser, runtime: runtime), "let go, a spare is made again")
        let tabKey = CEFPaneKey(pane: Self.pane(), profile: .default)
        let next = runtime.host(for: tabKey)
        #expect(next !== browserSpare && next.key == tabKey, "a tab's key takes the new spare")
        #expect(spares.takeParked(for: tabKey).isEmpty, "the new spare adopted a tab parked in the closed one")
    }

    /// Only the engine's own profile: beginning it touches no process-wide Chromium state.
    @Test func theEnginesPagesProfileIsOneOffTheRecordProfile() {
        let stores = BrowserSharedStores.inMemory()
        let engine = CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
        let profile = engine.beginPagesProfile()
        #expect(engine.beginPagesProfile() == profile, "begun once")
        #expect(stores.offTheRecord.isOffTheRecord(profile), "a page keeps nothing on disk")
        #expect(profile != .default)
    }

    private func pageKey(pane: BrowserPaneID = BrowserPaneID(rawValue: "cmux-page-test")) -> CEFPaneKey {
        CEFPaneKey(pane: pane, profile: pages, offTheRecord: true)
    }

    /// A tab of `host` asks Chromium for its window.
    private func build(_ host: CEFPaneHost, runtime: CEFRuntime) {
        let tab = CEFTab(id: .random(), profile: host.key.profile, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
    }

    private static func pane() -> BrowserPaneID { BrowserPaneID(rawValue: UUID().uuidString) }

    /// Chromium finished the one window being built: its OnAfterCreated, as `browser`.
    private static func comeUp(_ runtime: CEFRuntime, browser: Int32) throws {
        #expect(runtime.pendingWindows.count == 1)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
    }

    /// A runtime that outlives the test: a window that came up shows itself at the end of the turn
    /// (`CEFPaneHost.windowCreated`), after the test returned.
    private static func spyRuntime() throws -> (CEFRuntime, URL) {
        SpareSpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-spare-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime.spy(shim: try SpareSpyShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    private final class Counter { var value = 0 }
}

/// Stand-in shim functions: `cmux_shim_create_window` counts its calls and reports the browser
/// started (a window stays `creating` until a test sends its OnAfterCreated, `comeUp`); every other
/// function does nothing and returns 0.
private nonisolated enum SpareSpyShim {
    nonisolated(unsafe) static var createWindowCalls = 0

    static func reset() { createWindowCalls = 0 }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            SpareSpyShim.createWindowCalls += 1
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
