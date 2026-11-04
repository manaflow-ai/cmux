@testable import CmuxNextBrowser
import CmuxNextInput
import Foundation
import Testing

/// The default profile's spare Chromium window: an incognito window's, a cmux page's or a remote
/// machine's key never takes it; at most one untaken spare; none is built beside a window being built;
/// memory pressure holds it. Driven against a spy shim that counts `cmux_shim_create_window`; each
/// test has its own runtime, so its own spares.
@MainActor @Suite(.serialized) struct CEFSpareWindowKindsTests {
    private let pages = BrowserProfileID(rawValue: UUID())

    /// A live spare, so no window is being built: only the limit refuses a second spare.
    @Test func atMostOneUntakenSpare() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        #expect(spares.prepare(.browser, runtime: runtime))
        try Self.comeUp(runtime, browser: 10)
        #expect(spares.state(of: .browser) == .live)
        #expect(!runtime.hosts.values.contains { $0.isCreatingWindow }, "no window is being built")
        #expect(!spares.prepare(.browser, runtime: runtime), "a second untaken browser spare")
        #expect(SpareSpyShim.createWindowCalls == 1)
    }

    @Test func noSpareIsBuiltBesideAWindowBeingBuilt() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        build(runtime.host(for: CEFPaneKey(pane: Self.pane(), profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true)),
              runtime: runtime)
        #expect(!spares.prepare(.browser, runtime: runtime), "an incognito window is still being built")
        #expect(SpareSpyShim.createWindowCalls == 1)
    }

    @Test func incognitoPageAndRemoteKeysNeverTakeASpare() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        #expect(spares.prepare(.browser, runtime: runtime))
        let spare = try #require(spares.host(of: .browser))

        let incognito = CEFPaneKey(pane: Self.pane(), profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true)
        let remoteDefault = CEFPaneKey(pane: Self.pane(), profile: .default, machineKey: "machine-1")
        let popup = CEFPaneKey(pane: BrowserPaneID(rawValue: CEFPaneHost.popupPrefix + "x"), profile: .default)
        for key in [incognito, pageKey(), remoteDefault, popup] {
            #expect(spares.kind(for: key) == nil)
            #expect(runtime.host(for: key) !== spare)
        }
        #expect(spares.host(of: .browser) === spare, "still the untaken spare")
        #expect(spares.kind(for: CEFPaneKey(pane: Self.pane(), profile: .default)) == .browser)
        #expect(spares.kind(for: CEFPaneKey(pane: Self.pane(), profile: BrowserProfileID(rawValue: UUID()))) == nil,
                "another persistent profile has no spare")
    }

    /// The counter `debug.cef` reports as `window_built_on_key_turn`: a window built for a key a
    /// spare serves, because none was ready. Incognito and the spare's own window do not count.
    @Test func aWindowBuiltForAKeyASpareServesCounts() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        let incognito = CEFPaneKey(pane: Self.pane(), profile: BrowserProfileID(rawValue: UUID()), offTheRecord: true)
        build(runtime.host(for: incognito), runtime: runtime)
        #expect(spares.windowsBuiltOnKeyTurn == 0, "an incognito window has no spare to miss")
        try Self.comeUp(runtime, browser: 9)

        build(runtime.host(for: CEFPaneKey(pane: Self.pane(), profile: .default)), runtime: runtime)
        #expect(spares.windowsBuiltOnKeyTurn == 1, "the default profile's key found no spare")
    }

    /// Memory pressure holds the spares (`CEFEngine.holdSpareWindows`,
    /// from the warmup's memory consumer): holding keeps the untaken one (Chrome keeps its spare
    /// renderer at warning), critical closes it (`closeUntakenSpareWindows`), no spare is made, a
    /// taken spare whose tab closed before it joined is not given back, and a window that comes up
    /// asks for none. A tab Chromium parked in a closed spare leaves with it (`CEFOrphanTabs.rehome`):
    /// the next spare adopts nothing stale. Let go, a spare is made again.
    @Test func heldSparesCloseAndNoneIsMadeOrGivenBackUntilLetGo() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        let asked = Counter()
        spares.onNeeded = { asked.value += 1 }
        #expect(spares.prepare(.browser, runtime: runtime))
        try Self.comeUp(runtime, browser: 10)
        let taken = runtime.host(for: CEFPaneKey(pane: Self.pane(), profile: .default))
        let tab = CEFTab(id: .random(), profile: .default, host: taken, runtime: runtime)
        taken.add(tab)
        #expect(spares.prepare(.browser, runtime: runtime))
        try Self.comeUp(runtime, browser: 11)
        let browserSpare = try #require(spares.host(of: .browser))
        // An extension's `chrome.tabs.create` put a tab into the untaken spare's window.
        browserSpare.adoptChromiumTab(browser: 77)
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

        taken.removed(tab)
        #expect(spares.host(of: .browser) == nil, "a held spare was given back")
        spares.windowCameUp(taken)
        #expect(asked.value == askedBeforeHold, "a window that came up asked for a spare while held")

        spares.setHeld(false)
        #expect(spares.prepare(.browser, runtime: runtime), "let go, a spare is made again")
        let tabKey = CEFPaneKey(pane: Self.pane(), profile: .default)
        let next = runtime.host(for: tabKey)
        #expect(next !== browserSpare && next.key == tabKey, "a tab's key takes the new spare")
        #expect(spares.takeParked(for: tabKey).isEmpty, "the new spare adopted a tab parked in the closed one")
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
