@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextInput
import Testing

/// The App's Chromium engine is built on its first read, not in `AppServices.init` (p08-startup-024, Q1), and
/// its wiring (`engineDidCreate`) runs before any reader gets it, so the crash handlers are always set before
/// anything can run CefInitialize (`AppRunMarker.keepSignalHandlers`).
@MainActor struct ChromiumEngineSlotTests {
    /// Counts the engines a slot builds and the ones its hook saw.
    final class Builds {
        var made: [ObjectIdentifier] = []
        var wired: [ObjectIdentifier] = []
        var madeWhenWired: [Int] = []
        var rereadInHook: CEFEngine?
    }

    static func engine(_ stores: BrowserSharedStores = .inMemory()) -> CEFEngine {
        CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
    }

    static func slot(_ builds: Builds, rereadFrom holder: (() -> ChromiumEngineSlot?)? = nil) -> ChromiumEngineSlot {
        let fixture = engine()
        return ChromiumEngineSlot(stores: fixture.stores, waitDeadlines: fixture.waitDeadlines, make: { stores, deadlines in
            let engine = CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks(), waitDeadlines: deadlines,
                                   input: InputEventTap())
            builds.made.append(ObjectIdentifier(engine))
            return engine
        }, engineDidCreate: { engine in
            builds.wired.append(ObjectIdentifier(engine))
            builds.madeWhenWired.append(builds.made.count)
            builds.rereadInHook = holder?()?.engine
        })
    }

    @Test func theCacheBuildsNoEngineUntilItsFirstChromiumRead() {
        let builds = Builds()
        let slot = Self.slot(builds)
        let cache = TabContentCache(daemon: DaemonService(), chromium: slot, fileInput: NoFileInput())
        // The WebKit engine, the tab service and the stores come from the slot, not from an engine.
        _ = cache.webKit.profileStore
        _ = cache.browserTabs.offTheRecord
        #expect(cache.webKit.stores.siteZoom === slot.stores.siteZoom)
        #expect(builds.made.isEmpty)
        #expect(slot.built == nil)

        let engine = cache.cef
        #expect(builds.made == [ObjectIdentifier(engine)])
        #expect(engine.stores.offTheRecord === slot.stores.offTheRecord, "the engine is built over the slot's stores")
        #expect(engine.waitDeadlines === slot.waitDeadlines)
        _ = cache.cef
        #expect(builds.made.count == 1, "one engine per slot")
    }

    @Test func theHookWiresTheEngineOnceBeforeItsReaderGetsIt() {
        let builds = Builds()
        var holder: ChromiumEngineSlot?
        let slot = Self.slot(builds, rereadFrom: { holder })
        holder = slot

        let engine = slot.engine
        #expect(builds.wired == [ObjectIdentifier(engine)])
        #expect(builds.madeWhenWired == [1])
        #expect(builds.rereadInHook === engine, "a read from inside the hook gets the engine being wired, not a second one")
        _ = slot.engine
        #expect(builds.wired.count == 1)
        #expect(builds.made.count == 1)
    }

    @Test func aSlotOverABuiltEngineHandsItBack() {
        let engine = Self.engine()
        let slot = ChromiumEngineSlot(engine)
        #expect(slot.stores.offTheRecord === engine.stores.offTheRecord)
        #expect(slot.engine === engine)
    }

    /// The App: `AppServices.init` builds no engine (Q1), and the engine's first read sets the run marker's
    /// signal handlers (`onStartFailed`, `onReady`) before the reader can start Chromium.
    @Test func appServicesBuildsNoEngineAndItsFirstReadKeepsTheSignalHandlers() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cache.chromium.built == nil, "AppServices.init builds no Chromium engine")

        // The handlers live on the process's one runtime: clear what an earlier engine in this process set.
        let probe = Self.engine()
        probe.onStartFailed = nil
        probe.openURLWithoutWindow = nil
        #expect(probe.onStartFailed == nil)

        let engine = services.cache.cef
        #expect(engine.onStartFailed != nil, "keepSignalHandlers ran as the engine was built, before CefInitialize can run")
        #expect(engine.onReady != nil)
        #expect(engine.openURLWithoutWindow != nil, "the App's routes are on the engine its first reader gets")
        #expect(services.cache.chromium.built === engine)
    }
}
