import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
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
}
