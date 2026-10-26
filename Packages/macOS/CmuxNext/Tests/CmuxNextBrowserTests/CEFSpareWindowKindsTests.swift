@testable import CmuxNextBrowser
import Foundation
import Testing

/// p13-webui-016: one spare Chromium window per store kind (the default profile's and the cmux
/// pages profile's). A cmux page's key takes the pages spare instead of building a window on its
/// key's turn (`window_built_on_key_turn` stays 0); an incognito window's or a remote machine's
/// key never takes one; at most one untaken spare per kind. Driven against a spy shim that counts
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
        #expect(SpareSpyShim.createWindowCalls == 1, "no window built for the page")
        #expect(spares.windowsBuiltOnKeyTurn == 0)
    }

    @Test func atMostOneUntakenSparePerKind() throws {
        let (runtime, root) = try Self.spyRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = runtime.spareWindow
        spares.pagesProfile = pages
        #expect(spares.prepare(.pages, runtime: runtime))
        #expect(!spares.prepare(.pages, runtime: runtime), "a second untaken pages spare")
        #expect(!spares.prepare(.browser, runtime: runtime), "no spare is built beside a window being built")
        #expect(SpareSpyShim.createWindowCalls == 1)
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
        other.spareWindow.setWantsPages(false, runtime: other)
        #expect(other.spareWindow.host(of: .pages) == nil, "turning it off closes the untaken pages spare")
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

    @Test func theEnginesPagesProfileIsOneOffTheRecordProfile() {
        let stores = BrowserSharedStores.inMemory()
        let engine = CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks())
        let profile = engine.pagesProfile
        #expect(engine.pagesProfile == profile, "begun once")
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

    private static func spyRuntime() throws -> (CEFRuntime, URL) {
        SpareSpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-spare-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (CEFRuntime(shim: try SpareSpyShim.library(), storage: CEFProfileStorage(root: root)), root)
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` counts its calls and reports the browser
/// started (Chromium never finishes it, so a window stays `creating`); every other function does
/// nothing and returns 0.
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
