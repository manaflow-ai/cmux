import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Testing

/// A muted tab that hibernates wakes muted. The engine page restore makes is
/// new and starts unmuted, and nothing applied the slept-on mute, so the site
/// played with sound after the wake while the person had muted it (QA spree
/// 2026-10-21).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HibernatedTabKeepsMuteTests {
    @Test func aMutedTabWakesMuted() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await rig.hide(rig.page("muted", body: "<p>muted</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) }
        let cache = rig.services.cache
        let slept = try #require(cache.existingBrowser(key)?.tab as? HibernatedBrowserTab)
        var state = slept.state
        state.isAudioMuted = true
        let asleep = HibernatedBrowserTab(id: slept.id, engine: .cef, profile: slept.profileID, state: state,
                                          favicon: nil, restoreState: .chromium("saved"), snapshot: { nil })
        asleep.onWake = slept.onWake
        cache.swapPage(key, with: asleep)
        var made: MockBrowserTab?
        cache.makeCEFTab = { configuration in
            let page = MockBrowserEngine(kind: .cef).makeMockTab(configuration)
            made = page
            return page
        }
        cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the page woke") { made != nil && !(cache.existingBrowser(key)?.tab is HibernatedBrowserTab) }
        let woken = try #require(cache.existingBrowser(key)?.tab)
        #expect(woken.state.isAudioMuted, "the woken page plays with sound")
    }
}
