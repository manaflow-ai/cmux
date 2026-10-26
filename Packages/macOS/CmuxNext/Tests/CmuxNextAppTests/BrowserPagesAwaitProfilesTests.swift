import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserHistory
@testable import CmuxNextDaemon
import CmuxNextInput
import CmuxNextLaunch
import Foundation
import Testing

/// p08-startup-028: no engine makes a browser tab's page before the browser profiles' launch read is
/// done. Before, a restored tab's page could be made with the profile chosen from an empty book (a
/// deleted profile's tab recreated its store); now the pane gets no page until the read's event, then
/// asks again and the page takes the profile the loaded book gives.
@MainActor @Suite(.serialized) struct BrowserPagesAwaitProfilesTests {
    @Test func noEngineMakesAPageBeforeTheProfilesLoad() throws {
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
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 2_801), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }

        #expect(cache.browser(for: tab) == nil, "a page was made before the profiles loaded")
        #expect(cache.browser(for: tab) == nil, "a second ask made a page before the profiles loaded")
        #expect(made.profiles.isEmpty, "an engine made a page before the profiles loaded")
        #expect(cache.existingBrowser(tab.id) == nil)
        #expect(profilesLoaded.waitingCount == 1, "a second ask waits twice")
        #expect(settled == 0, "a page is pending: Chromium's warm-up waits for it")

        let profile = BrowserProfileID(rawValue: UUID())
        book.loaded = profile
        profilesLoaded.signal()
        #expect(ready == [tab.id], "the pane asks again once the profiles loaded")
        #expect(settled == 1)
        let entry = try #require(cache.browser(for: tab), "the page is made once the profiles loaded")
        #expect(made.profiles == [profile], "the page took a profile chosen before the profiles loaded")
        #expect(entry.tab.profileID == profile)
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
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 2_803), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        #expect(cache.browser(for: tab) == nil)
        cache.release(tab.id)
        profilesLoaded.signal()
        #expect(ready.isEmpty, "a released tab was asked for again")
    }

    /// With no launch read (tests, a later service), pages are made at once, as before.
    @Test func withNoLaunchReadThePageIsMadeAtOnce() throws {
        let cache = Self.cache()
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 2_804), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        _ = try #require(cache.browser(for: tab))
    }

    /// The app's launch read is the profile service's: it is done once the book applied, and `loaded()` waits for it.
    @Test func theProfilesLoadSignalsTheRead() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-profiles-read-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let read = services.browserProfiles.loadRead
        services.cache.enginesAwait = read
        #expect(!read.isSignaled, "the read is done before the profiles were read")
        services.browserProfiles.load(directory: directory)
        await services.browserProfiles.loaded()
        #expect(read.isSignaled, "the profiles loaded but the pages still wait")
        #expect(services.browserProfiles.isLoaded)
        await services.browserProfiles.flush()
    }

    /// Chromium runs, so a New Tab page is made in the pane's turn (`ChromiumNewTabNow`) once nothing holds it.
    private static func cache() -> TabContentCache {
        let cache = TabContentCache(daemon: DaemonService(), chromium: ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())), fileInput: NoFileInput())
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        return cache
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
