import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextSettings
import Foundation
import CmuxNextWakeups
import Testing

/// The App's Chromium engine is built at its first Chromium need (a tab, a page, the warm-up), not in
/// `AppServices.init` nor by the launch wiring after it (p08-startup-024, Q1), and its wiring (`engineDidCreate`)
/// runs before any reader gets it, so the crash handlers are always set before anything can run CefInitialize
/// (`AppRunMarker.keepSignalHandlers`). Serialized: the handlers and the settings land on the process's one runtime.
@MainActor @Suite(.serialized) struct ChromiumEngineSlotTests {
    /// Counts the engines a slot builds and the ones its hook saw.
    final class Builds {
        var made: [ObjectIdentifier] = []
        var wired: [ObjectIdentifier] = []
        var madeWhenWired: [Int] = []
        var rereadInHook: CEFEngine?
        var stopped: [ObjectIdentifier] = []
        /// What ran when, in order: "hook", "work 1", ...
        var order: [String] = []
    }

    static func engine(_ stores: BrowserSharedStores = .inMemory()) -> CEFEngine {
        CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
    }

    static func slot(_ builds: Builds, rereadFrom holder: (() -> ChromiumEngineSlot?)? = nil) -> ChromiumEngineSlot {
        let fixture = engine()
        return ChromiumEngineSlot(stores: fixture.stores, waitDeadlines: fixture.waitDeadlines, source: CEFRuntimeSource(layout: nil),
                                  make: { stores, deadlines, source in
            let engine = CEFEngine(source: source, stores: stores, signInCallbacks: CEFSignInCallbacks(), waitDeadlines: deadlines,
                                   input: InputEventTap())
            builds.made.append(ObjectIdentifier(engine))
            return engine
        }, engineDidCreate: { engine in
            builds.wired.append(ObjectIdentifier(engine))
            builds.madeWhenWired.append(builds.made.count)
            builds.order.append("hook")
            builds.rereadInHook = holder?()?.engine
        }, stop: { builds.stopped.append(ObjectIdentifier($0)) })
    }

    /// Clears the run marker's handlers an earlier engine in this process set on the one runtime, so a check
    /// that they are set proves this build set them.
    static func clearRuntimeHandlers() {
        CEFRuntime.shared.onReady = nil
        CEFRuntime.shared.onStartFailed = nil
        CEFRuntime.shared.openURLWithoutWindow = nil
    }

    @Test func theCacheBuildsNoEngineUntilItsFirstChromiumRead() {
        let builds = Builds()
        let slot = Self.slot(builds)
        let cache = TabContentCache(daemon: DaemonService(), chromium: slot, fileInput: NoFileInput(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        // The WebKit engine, the tab service and the stores come from the slot, not from an engine.
        _ = cache.webKit.profileStore
        _ = cache.browserTabs.offTheRecord
        #expect(cache.webKit.stores.siteZoom === slot.stores.siteZoom)
        // "Can Chromium open a tab?" and "does Chromium run?" are answered without one.
        #expect(cache.browserTabs.cefUnavailable() == .notBundled)
        #expect(!cache.chromiumNow.runs())
        #expect(cache.chromiumNow.make(BrowserTabConfiguration()) == nil)
        #expect(builds.made.isEmpty)
        #expect(slot.built == nil)

        let engine = cache.cef
        #expect(builds.made == [ObjectIdentifier(engine)])
        #expect(engine.stores.offTheRecord === slot.stores.offTheRecord, "the engine is built over the slot's stores")
        #expect(engine.waitDeadlines === slot.waitDeadlines)
        #expect(engine.runtimeSource === slot.source)
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

    /// A follower's work waits for the engine without building it, runs after the hook in the order asked, and
    /// runs at once once the engine exists.
    @Test func workAskedBeforeTheEngineRunsAsItIsBuiltAfterTheHook() {
        let builds = Builds()
        let slot = Self.slot(builds)
        slot.whenBuilt { _ in builds.order.append("work 1") }
        slot.whenBuilt { _ in builds.order.append("work 2") }
        #expect(slot.built == nil, "asking for work builds no engine")
        #expect(builds.order.isEmpty)

        _ = slot.engine
        #expect(builds.order == ["hook", "work 1", "work 2"])
        slot.whenBuilt { _ in builds.order.append("work 3") }
        #expect(builds.order == ["hook", "work 1", "work 2", "work 3"])
        _ = slot.engine
        #expect(builds.order.count == 4, "each work runs once")
    }

    @Test func aSlotOverABuiltEngineHandsItBack() {
        let engine = Self.engine()
        let slot = ChromiumEngineSlot(engine)
        #expect(slot.stores.offTheRecord === engine.stores.offTheRecord)
        #expect(slot.source === engine.runtimeSource)
        #expect(slot.built === engine)
        #expect(slot.engine === engine)
    }

    /// Quit (`QuitCoordinator`'s `stopBrowserEngines` calls `cache.chromium.shutdown()`): a slot that built no engine
    /// stops nothing and builds none; once a reader built it, quit stops that engine.
    @Test func quitStopsOnlyAnEngineThatWasBuilt() async {
        let builds = Builds()
        let slot = Self.slot(builds)
        await slot.shutdown()
        #expect(builds.stopped.isEmpty, "no engine, nothing stopped")
        #expect(slot.built == nil, "quit builds no engine")

        let engine = slot.engine
        await slot.shutdown()
        #expect(builds.stopped == [ObjectIdentifier(engine)])
    }

    /// The App's hook holds the crash services themselves: it sets the run marker's signal handlers on an engine
    /// built with no `AppServices` alive (a reader that outlives it, a teardown at quit).
    @Test func theCrashHookNeedsNoAppServices() {
        let crashRecovery = CrashRecoveryService(bundleID: nil, runMarker: nil, work: BackgroundWork(label: "test.crash-hook"),
                                                 mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let reporter = AppCrashReporting(environment: AppEnvironment.current([:])).reporter
        var routed: [ObjectIdentifier] = []
        let fixture = Self.engine()
        let slot = ChromiumEngineSlot(stores: fixture.stores, waitDeadlines: fixture.waitDeadlines, source: CEFRuntimeSource(layout: nil),
                                      make: { CEFEngine(source: $2, stores: $0, signInCallbacks: CEFSignInCallbacks(), waitDeadlines: $1, input: InputEventTap()) },
                                      engineDidCreate: AppServices.chromiumEngineHook(crashRecovery: crashRecovery, reporter: reporter,
                                                                                      routes: { routed.append(ObjectIdentifier($0)) }),
                                      stop: { _ in })
        Self.clearRuntimeHandlers()

        let engine = slot.engine
        #expect(CEFRuntime.shared.onStartFailed != nil, "keepSignalHandlers ran as the engine was built, before CefInitialize can run")
        #expect(CEFRuntime.shared.onReady != nil)
        #expect(routed == [ObjectIdentifier(engine)], "then the window routes")
    }

    /// The launch: `AppServices.init` and what `applicationDidFinishLaunching` reads before the first frame (the page
    /// host behind `webUI` and the icon picker, the tab service's Chromium question, the link-click, managed-policy,
    /// password and search followers) build no engine. The first Chromium read builds it, with the handlers and
    /// the settings the followers hold.
    @Test func theLaunchWiringBuildsNoEngineAndTheFirstReadGetsTheSettings() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chromium-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"browser":{"links":{"cmdClick":"currentTab"},"passwords":{"offerToSave":false}}}"#.utf8).write(to: url)

        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cache.chromium.built == nil, "AppServices.init builds no Chromium engine")
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        let mapping = BrowserLinkClickMapping(settings.snapshot.browserLinkClicks)
        #expect(mapping != BrowserLinkClickMapping(BrowserLinkClickSetting()), "the file's link clicks differ from the defaults")

        // The launch path's readers (AppDelegate.applicationDidFinishLaunching, startSettingsAndControl).
        _ = services.iconPicker
        _ = services.webUI.chromium?.isAvailable
        _ = services.cache.browserTabs.cefUnavailable()
        _ = services.cache.chromiumNow.runs()
        CEFPasswordPolicy.set(offerToSave: true, generate: true)  // what an earlier engine in this process left
        let followers = BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, chromium: services.cache.chromium, on: services.mainWork)
            + BrowserOmnibarPreference.follow(settings, cache: services.cache, on: services.mainWork)  // the first values apply now
        #expect(services.cache.chromium.built == nil, "the launch wiring builds no Chromium engine")
        #expect(CEFPasswordPolicy.offerToSave, "nothing reached Chromium's settings without an engine")
        await services.cache.chromium.shutdown()
        #expect(services.cache.chromium.built == nil, "quit with no engine builds none")

        Self.clearRuntimeHandlers()
        let engine = services.cache.cef
        #expect(CEFRuntime.shared.onStartFailed != nil, "keepSignalHandlers ran as the engine was built, before CefInitialize can run")
        #expect(CEFRuntime.shared.onReady != nil)
        #expect(engine.openURLWithoutWindow != nil, "the App's routes are on the engine its first reader gets")
        #expect(engine.linkClicks == mapping, "browser.links.* reached the engine as it was built")
        #expect(!CEFPasswordPolicy.offerToSave, "browser.passwords.offerToSave reached Chromium as its engine was built")
        #expect(services.cache.chromium.built === engine)
        withExtendedLifetime(followers) {}
    }
}
