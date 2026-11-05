import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import Testing

/// A page that replaces a tab's page takes the tab's visibility: hidden when the tab is not on
/// screen, shown when it is. A new Chromium page starts visible (`CEFTab.isOccluded` false), and
/// Chromium draws in a child window an ancestor's `isHidden` or alpha does not reliably cover, so a
/// replacement that was never told it is hidden drew under the tab on screen. Leo saw a Cloud
/// chat's Claude sign-in page (ChatMachineSignInTab, adopted through `replacePage`) show through
/// the translucent agent pane under "Reconnecting…" and under the transcript (2026-11-05: "This is
/// pretty bad").
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ReplacedPageVisibilityTests {
    private func page() -> MockBrowserTab {
        MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://claude.ai/oauth")))
    }

    /// `key`'s tab, installed and shown in the rig's pane, then hidden when `hidden`.
    private func installed(_ rig: HiddenPageHibernationTests.Rig, key: String, hidden: Bool) throws {
        let cache = rig.services.cache
        cache.install(page(), for: key)
        cache.present(key, by: rig.pane, presence: .visible)
        try #require(cache.phase(of: key) == .mountedVisible)
        guard hidden else { return }
        cache.withdraw(key, by: rig.pane)
        try #require(cache.phase(of: key) == .mountedHidden)
    }

    /// The ordinary path: a Chromium page whose tab leaves the screen is hidden, and shows again
    /// when its tab does.
    @Test func aPageWhoseTabIsDeselectedIsHidden() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = "deselected"
        let shown = page()
        rig.services.cache.install(shown, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try #require(rig.services.cache.phase(of: key) == .mountedVisible)
        #expect(!shown.isContentHidden)
        rig.services.cache.withdraw(key, by: rig.pane)
        #expect(shown.isContentHidden, "a deselected tab's page draws under the tab on screen")
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        #expect(!shown.isContentHidden)
    }

    @Test func aPageAdoptedIntoAHiddenTabIsHidden() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let tab = TabModel(TabSnapshot(surface: 1))
        try installed(rig, key: tab.id, hidden: true)
        let adopted = page()
        rig.services.cache.replacePage(of: tab, with: adopted)
        #expect(adopted.isContentHidden, "the adopted page draws under the tab on screen")
    }

    @Test func aPageAdoptedIntoAShownTabShows() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let tab = TabModel(TabSnapshot(surface: 2))
        try installed(rig, key: tab.id, hidden: false)
        let adopted = page()
        rig.services.cache.replacePage(of: tab, with: adopted)
        #expect(!adopted.isContentHidden)
    }

    @Test func aPageSwappedIntoAHiddenTabIsHidden() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = "swapped-hidden"
        try installed(rig, key: key, hidden: true)
        let woken = page()
        rig.services.cache.swapPage(key, with: woken)
        #expect(woken.isContentHidden, "the swapped-in page draws under the tab on screen")
    }

    /// A restored tab that waits for the user (`deferred`): a deferred page started in a hidden tab
    /// (`startDeferred`, e.g. an agent's page asked for while its tab is not on screen) is hidden.
    @Test func aDeferredPageStartedInAHiddenTabIsHidden() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let started = try startedDeferredPage(rig, surface: 4, hidden: true)
        #expect(started.isContentHidden, "the started page draws under the tab on screen")
    }

    @Test func aDeferredPageStartedInAShownTabShows() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let started = try startedDeferredPage(rig, surface: 5, hidden: false)
        #expect(!started.isContentHidden)
    }

    /// A deferred Chromium tab on `surface`, shown in the rig's pane (then hidden when `hidden`), whose
    /// page is started: the started page is the one returned.
    private func startedDeferredPage(_ rig: HiddenPageHibernationTests.Rig, surface: UInt64, hidden: Bool) throws -> MockBrowserTab {
        let cache = rig.services.cache
        let url = URL(string: "https://claude.ai/oauth")
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: url?.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        cache.findTab = { $0 == tab.id ? tab : nil }
        _ = cache.deferred(tab, url: url)
        cache.present(tab.id, by: rig.pane, presence: .visible)
        try #require(cache.phase(of: tab.id) == .mountedVisible)
        if hidden {
            cache.withdraw(tab.id, by: rig.pane)
            try #require(cache.phase(of: tab.id) == .mountedHidden)
        }
        let started = page()
        cache.pageRequests.adopt(started, surface: tab.surface)
        cache.startDeferred(tab.id, url: nil)
        try #require(cache.existingBrowser(tab.id)?.tab === started, "the started page is the tab's")
        return started
    }
}
