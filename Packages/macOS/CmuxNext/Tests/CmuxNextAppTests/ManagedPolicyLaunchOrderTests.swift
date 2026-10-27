import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p08-startup-101: the managed policy (MDM) is critical. `AppServices.applyManagedPolicyAtLaunch` applies the settings launch read's
/// forced values (prefetched off main) before any feature starts and before any page engine makes a page, without
/// waiting for the settings controller's first load: a URL the organization blocks never loads, in a WebKit tab too
/// (Chromium enforces Chrome's policy domain itself from its start).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ManagedPolicyLaunchOrderTests {
    /// A temporary settings file (`{}`) and its folder.
    final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "cnc-managed-launch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: settingsFile)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var settingsFile: URL { url.appending(path: "cmux-next.json") }
    }

    /// A settings controller made as `AppDelegate` makes it: on the launch read whose managed layer forces `forced`.
    /// Its own reader (`later`, what a reload reads) has no policy by default, so a step that read the preferences
    /// again (instead of the prefetched values) would see none. Not started: its first load has not run.
    static func launchSettings(_ folder: Folder, registry: ActionRegistry, forced: [String: JSONValue],
                               later: ManagedPreferences = ManagedPreferences()) async -> SettingsController {
        let pending = SettingsController.startLaunchRead(on: BackgroundWork(label: "test.managed-launch"), prepareFileURL: { folder.settingsFile },
                                                         managedReader: FixedManagedPreferenceReader(ManagedPreferences(forced: forced)))
        let launch = await pending.read.finished()
        return SettingsController(registry: registry, design: DesignSettings(), fileURL: folder.settingsFile,
                                  managedReader: FixedManagedPreferenceReader(later), managedWatchFiles: [], launch: launch)
    }

    /// Runs the main run loop until a task posted now in the policy observation's class (`automation`, one FIFO)
    /// has run, so a flush the last load posted has run too.
    static func drainPolicyFlushes(_ services: AppServices) -> Bool {
        var drained = false
        services.mainWork.post(.automation, owner: "test.afterPolicyFlush") { drained = true }
        return runMainLoop(until: { drained })
    }

    static func blocklist(_ filters: String...) -> JSONValue { .array(filters.map(JSONValue.string)) }

    /// The base defect: the WebKit URL filter followed `managedPolicy`, which is empty until the first load, so a
    /// follower started before the load applied no filter. It now reads the launch read's forced values.
    @Test func theWebKitFilterStartedBeforeTheFirstLoadBlocksAndTheLoadKeepsIt() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let folder = try Folder()
        let settings = await Self.launchSettings(folder, registry: services.registry,
                                                 forced: ["URLBlocklist": Self.blocklist("blocked.example")])
        let webKit = services.cache.webKit
        #expect(webKit.urlFilter == .none)
        let followers = BrowserManagedPolicyPreference.follow(settings, webKit: webKit, chromium: services.cache.chromium,
                                                              on: services.mainWork)
        let blocked = try #require(URL(string: "https://blocked.example/front"))
        #expect(settings.loadCount == 0)
        #expect(webKit.urlFilter.blocks(blocked), "the filter applied before the first load is empty")
        #expect(!webKit.urlFilter.blocks(try #require(URL(string: "https://allowed.example/"))))

        settings.start()
        defer { settings.stop() }
        // In start()'s turn: the launch read's load alone. The watcher's reload, which reads this fixture's empty
        // reader, has not run; the next test covers it.
        #expect(settings.loadCount == 1)
        #expect(settings.managedPolicyInEffect == ["URLBlocklist": Self.blocklist("blocked.example")],
                "the first load hands on another policy than the launch read's")
        #expect(webKit.urlFilter.blocks(blocked), "the first load cleared the filter")
        withExtendedLifetime(followers) {}
    }

    /// A reload after the launch reads the managed preferences again and the WebKit filter follows what it reads:
    /// the same policy keeps the filter, a removed one clears it. The drain waits for the observation's flush, so
    /// the kept case is not a flush that has not run yet.
    @Test(arguments: [true, false]) func theReloadAfterTheLaunchKeepsOrRemovesTheFilter(policyStays: Bool) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let folder = try Folder()
        let forced: [String: JSONValue] = ["URLBlocklist": Self.blocklist("blocked.example")]
        let settings = await Self.launchSettings(folder, registry: services.registry, forced: forced,
                                                 later: ManagedPreferences(forced: policyStays ? forced : [:]))
        let webKit = services.cache.webKit
        let followers = BrowserManagedPolicyPreference.follow(settings, webKit: webKit, chromium: services.cache.chromium,
                                                              on: services.mainWork)
        let blocked = try #require(URL(string: "https://blocked.example/front"))
        #expect(webKit.urlFilter.blocks(blocked))

        settings.start()
        defer { settings.stop() }
        await settings.waitForLoad(atLeast: 2)  // the watcher's initial reload, which reads `later`
        #expect(Self.drainPolicyFlushes(services), "the main-thread scheduler never ran the posted task")
        #expect(settings.managedPolicyInEffect == (policyStays ? forced : [:]))
        #expect(webKit.urlFilter.blocks(blocked) == policyStays,
                policyStays ? "the reload cleared the filter it still reads" : "the filter outlived the removed policy")
        withExtendedLifetime(followers) {}
    }

    /// The launch's three critical steps, in the allowlist's order and in the caller's turn: features on the
    /// registry, the owning services' refusals and the WebKit filter are all in place before the settings load and
    /// before anything could start a feature or make a page.
    @Test func theLaunchPolicyIsCriticalAndAppliesBeforeTheFirstLoad() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let folder = try Folder()
        let settings = await Self.launchSettings(folder, registry: services.registry, forced: [
            "DisabledFeatures": .array([.string(ActionFeature.remoteHosts.rawValue)]),
            "URLBlocklist": Self.blocklist("blocked.example"),
        ])
        let s = StartupTestScheduler()
        let followersBefore = services.lifetimeFollowers.count

        services.applyManagedPolicyAtLaunch(settings, on: s.startup)

        #expect(settings.loadCount == 0, "the steps read the launch read, not a load")
        #expect(services.registry.disabledFeatures == [.remoteHosts])
        #expect(services.serverReach.policyDisabled, "the enforcer refused the disabled feature in the same turn")
        #expect(services.cache.webKit.urlFilter.blocks(try #require(URL(string: "https://blocked.example/"))))
        #expect(services.lifetimeFollowers.count > followersBefore, "the policy followers are not kept")
        let names = s.startup.log.records.map(\.name.description)
        #expect(names == ["Settings.applyManagedFeaturesNow", "ManagedPolicyBridge.start", "FeaturePolicyEnforcer.start"])
        #expect(s.startup.log.records.allSatisfy { $0.priority == .critical })
        #expect(s.startup.log.violations.isEmpty, "a policy step is not on the critical allowlist")
        let allowlist = StartupScheduler.criticalAllowlist.map(\.description)
        #expect(names.compactMap { allowlist.firstIndex(of: $0) } == Array(3 ... 5), "the steps are not rows 4 to 6 of the allowlist")
    }

    /// The acceptance, on WebKit: with the launch policy applied as `AppDelegate` applies it, the front tab's
    /// restored blocked page never reaches the server and shows the organization's error; an allowed page loads.
    @Test func aBlockedPageRestoredInTheFrontWebKitTabNeverLoads() async throws {
        _ = NSApplication.shared
        let server = try await BrowserEngineStateRestoreTests.PageServer.start()
        defer { server.stop() }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let folder = try Folder()
        let blocked = server.url("/c"), allowed = server.url("/a")
        let settings = await Self.launchSettings(folder, registry: services.registry, forced: [
            "URLBlocklist": Self.blocklist("127.0.0.1:\(server.port)/c"),
        ])
        services.applyManagedPolicyAtLaunch(settings, on: StartupTestScheduler().startup)

        let tab = services.cache.webKit.makeWebKitTab()
        defer { tab.close() }
        let (events, sink) = AsyncStream.makeStream(of: BrowserNavigationEvent.self)
        let observer = tab.observeNavigationEvents { sink.yield($0) }
        defer { tab.removeNavigationObserver(observer) }
        var next = events.makeAsyncIterator()

        tab.load(blocked)  // the restore's load of the front tab's saved address
        var refusal: BrowserLoadError?
        while refusal == nil, let event = await next.next() {
            if case .failed(_, let error) = event { refusal = error }
            if case .committed = event { break }
        }
        #expect(refusal?.code == ChromiumNetError.blockedByAdministrator, "the blocked page was not refused: \(String(describing: refusal))")
        #expect(refusal?.failingURL == blocked)

        tab.load(allowed)
        var finished = false
        while !finished, let event = await next.next() {
            if case .finished = event { finished = true }
            if case .failed(_, let error) = event, error.failingURL == allowed { break }
        }
        #expect(finished, "the allowed page did not load")
        #expect(server.count("/a") == 1)
        #expect(server.count("/c") == 0, "the blocked page reached the server")
        withExtendedLifetime(settings) {}
    }
}
