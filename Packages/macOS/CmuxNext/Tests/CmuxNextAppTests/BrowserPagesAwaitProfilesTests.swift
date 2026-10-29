import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserHistory
@testable import CmuxNextDaemon
import CmuxNextInput
import CmuxNextLaunch
import Foundation
import Testing

/// No engine makes a browser tab's page before the browser profiles' launch read is
/// done. Before, a restored tab whose record names a deleted profile got a page in that profile's store
/// (chosen from the empty book), which reopened the store and kept `cleanUpDeletedProfiles` from removing
/// it. Now the page waits for the read's event, and the read's step makes it, shown in a pane or not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserPagesAwaitProfilesTests {
    /// A tab no pane shows (an agent's background tab) gets its page on the signal with no re-ask.
    @Test func noEngineMakesAPageBeforeTheProfilesLoadAndTheReadMakesIt() throws {
        let cache = Self.cache()
        let book = ProfileBook()
        let made = MadePages()
        cache.browserProfile = { _ in book.loaded }
        cache.chromiumNow.make = { configuration in
            made.profiles.append(configuration.profile)
            return MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
        }
        let profilesLoaded = LaunchReadEvent("BrowserProfiles.loaded")
        cache.enginesAwait = profilesLoaded
        var ready: [String] = []
        cache.onBrowserReady = { ready.append($0) }
        var settled = 0
        cache.onPagesSettled = { settled += 1 }
        let tab = Self.tab(2_801)
        cache.findTab = { $0 == tab.id ? tab : nil }
        defer { cache.release(tab.id) }

        #expect(cache.browser(for: tab) == nil, "a page was made before the profiles loaded")
        #expect(cache.browser(for: tab) == nil, "a second ask made a page before the profiles loaded")
        #expect(made.profiles.isEmpty, "an engine made a page before the profiles loaded")
        #expect(cache.existingBrowser(tab.id) == nil)
        #expect(profilesLoaded.waitingCount == 1, "a second ask waits twice")
        #expect(cache.hasPendingPages, "a page waits: Chromium's warm-up waits for it")
        #expect(settled == 0)

        let profile = BrowserProfileID(rawValue: UUID())
        book.loaded = profile
        profilesLoaded.signal()
        let entry = try #require(cache.existingBrowser(tab.id), "the read made no page for a tab no pane asked again for")
        #expect(made.profiles == [profile], "the page took a profile chosen before the profiles loaded")
        #expect(entry.tab.profileID == profile)
        #expect(ready == [tab.id], "panes showing the tab re-show once, with the page")
        #expect(settled == 1)
        #expect(!cache.hasPendingPages)
    }

    /// A tab released and asked for again before the read keeps one step: one page, one re-show.
    @Test func aTabReleasedAndAskedForAgainGetsOnePage() {
        let cache = Self.cache()
        var makes = 0
        cache.chromiumNow.make = { makes += 1; return MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        let profilesLoaded = LaunchReadEvent("BrowserProfiles.loaded")
        cache.enginesAwait = profilesLoaded
        var ready: [String] = []
        cache.onBrowserReady = { ready.append($0) }
        let tab = Self.tab(2_805)
        cache.findTab = { $0 == tab.id ? tab : nil }
        defer { cache.release(tab.id) }

        #expect(cache.browser(for: tab) == nil)
        cache.release(tab.id, displacing: false)
        #expect(cache.browser(for: tab) == nil)
        profilesLoaded.signal()
        #expect(makes == 1, "a stale step made a second page for the tab")
        #expect(ready == [tab.id], "a stale step re-showed the tab again")
        #expect(cache.existingBrowser(tab.id) != nil)
    }

    /// A WebKit tab waits too: its page is made in the pane's turn, so nothing later could fix its store.
    @Test func aWebKitTabWaitsForTheProfilesToo() {
        let cache = Self.cache()
        cache.enginesAwait = LaunchReadEvent("BrowserProfiles.loaded")
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 2_802), kind: .browser, url: "https://example.com/",
                                       browserRenderer: "frontend", browserEngine: "webkit"))
        defer { cache.release(tab.id) }
        #expect(cache.browser(for: tab) == nil, "a WebKit page was made before the profiles loaded")
        #expect(cache.existingBrowser(tab.id) == nil)
    }

    /// A tab closed while it waited gets no page and no pane request when the profiles load.
    @Test func aTabReleasedWhileItWaitedIsNotAskedForAgain() {
        let cache = Self.cache()
        cache.chromiumNow.make = { _ in Issue.record("a released tab's page was made"); return nil }
        let profilesLoaded = LaunchReadEvent("BrowserProfiles.loaded")
        cache.enginesAwait = profilesLoaded
        var ready: [String] = []
        cache.onBrowserReady = { ready.append($0) }
        let tab = Self.tab(2_803)
        cache.findTab = { $0 == tab.id ? tab : nil }
        #expect(cache.browser(for: tab) == nil)
        cache.release(tab.id)
        profilesLoaded.signal()
        #expect(ready.isEmpty, "a released tab was asked for again")
        #expect(!cache.hasPendingPages)
    }

    /// A restored page deferred after two quick crashes makes no engine, so it does not wait for the read.
    @Test func aDeferredRestoredPageDoesNotWait() throws {
        let cache = Self.cache()
        cache.chromiumNow.make = { _ in Issue.record("a deferred page made an engine page"); return nil }
        cache.enginesAwait = LaunchReadEvent("BrowserProfiles.loaded")
        cache.defersRestoredPages = true
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 2_806), kind: .browser, url: "https://example.com/",
                                       browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        let entry = try #require(cache.browser(for: tab), "a deferred page waited for the profiles")
        #expect(entry.tab is DeferredBrowserTab)
    }

    /// With no launch read (tests, a later service), pages are made at once, as before.
    @Test func withNoLaunchReadThePageIsMadeAtOnce() async throws {
        let cache = Self.cache()
        let tab = Self.tab(2_804)
        defer { cache.release(tab.id) }
        await cache.enginesReady()
        _ = try #require(cache.browser(for: tab))
    }

    /// Callers that need a page in their own turn (an automation tab) wait for the read first.
    @Test func enginesReadyReturnsOnTheSignal() async {
        let cache = Self.cache()
        let profilesLoaded = LaunchReadEvent("BrowserProfiles.loaded")
        cache.enginesAwait = profilesLoaded
        let waiting = Task { @MainActor in await cache.enginesReady(); return profilesLoaded.isSignaled }
        await Task.yield()
        profilesLoaded.signal()
        #expect(await waiting.value, "enginesReady returned before the read was done")
    }

    /// The app's wiring, with nothing set by hand: a restored tab whose record names a profile deleted in an
    /// earlier run gets no page until the real profile service read its book, then a page in the default
    /// store (not the deleted profile's), and the deleted profile's data is still removed. Fails on the base,
    /// where the page was made at once in the deleted profile's store.
    @Test func aDeletedProfilesTabOpensInTheDefaultStoreAfterTheRealLoad() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let deleted = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-profiles-read-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"pending_cleanup":["\#(deleted)"]}"#.utf8)
            .write(to: directory.appending(path: "profiles.json"))
        let cache = services.cache
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 2_807), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                                       browserRenderer: "frontend", browserEngine: "cef", browserProfileID: deleted))
        cache.findTab = { $0 == tab.id ? tab : nil }
        cache.defersRestoredPages = false
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        let made = MadePages()
        cache.chromiumNow.make = { configuration in
            made.profiles.append(configuration.profile)
            return MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
        }
        defer { cache.release(tab.id) }

        services.browserProfiles.load(directory: directory)
        #expect(cache.browser(for: tab) == nil, "a page was made before the profiles were read")
        #expect(made.profiles.isEmpty, "an engine made a page before the profiles were read")
        await services.browserProfiles.loaded()
        let entry = try #require(cache.existingBrowser(tab.id), "the profiles loaded but the tab has no page")
        #expect(made.profiles == [.default], "a deleted profile's tab reopened its store")
        #expect(entry.tab.profileID == .default)
        // The cleanup saw no engine open the deleted profile, so it removes it (and saves the book).
        try await DeleteProfileDerivedStoresTests.until { services.browserProfiles.book.pendingCleanup.isEmpty }
        await services.browserProfiles.flush()
    }

    /// Chromium runs, so a New Tab page is made in the pane's turn (`ChromiumNewTabNow`) once nothing holds it.
    private static func cache() -> TabContentCache {
        let cache = TabContentCache(daemon: DaemonService(), chromium: ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())), fileInput: NoFileInput(), mainWork: linklessMainWork())
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        return cache
    }

    private static func tab(_ surface: UInt64) -> TabModel {
        TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                             browserRenderer: "frontend", browserEngine: "cef"))
    }
}

@MainActor
private final class ProfileBook {
    var loaded: BrowserProfileID = .default
}

@MainActor
private final class MadePages {
    var profiles: [BrowserProfileID] = []
}
