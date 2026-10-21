import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Lawrence 2026-10-20: "I click on a hibernated tab and the Omni bar is blank until a second
/// later". Showing a hibernated tab wakes it: a new engine page replaces the placeholder, with a
/// new toolbar. That page reports no address yet (WebKit, before its restored item loads) or a
/// blank one (a Chromium browser is created on an empty URL so its saved history can be restored,
/// and reports `about:blank` first), and the new omnibar showed that until the page committed.
/// The omnibar keeps the address the tab slept on from the first frame of the wake, and changes
/// only when the woken page reports another real address.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HibernatedTabOmnibarTests {
    @Test func aWokenChromiumTabShowsItsAddressInTheFirstFrame() async throws {
        let wake = try await ChromiumWake()
        defer { wake.rig.close() }
        let firstFrame = try await wake.show()
        #expect(!wake.asleepText.isEmpty, "the hibernated tab's own omnibar was blank")
        #expect(firstFrame == wake.asleepText, "the woken tab's omnibar showed \(firstFrame.debugDescription), not its address")
        #expect(wake.bar.displayedText == wake.asleepText)
    }

    @Test func aWokenWebKitTabShowsItsAddressInTheFirstFrame() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await rig.hide(rig.page("asleep", body: "<p>asleep</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) }
        let asleepText = try #require(rig.services.cache.existingBrowser(key)).chrome.addressBar.displayedText
        var firstFrame: String?
        rig.services.cache.onBrowserReady = { [weak cache = rig.services.cache] ready in
            guard ready == key, firstFrame == nil, !(cache?.existingBrowser(ready)?.tab is HibernatedBrowserTab) else { return }
            firstFrame = cache?.existingBrowser(ready)?.chrome.addressBar.displayedText
        }
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the page woke") { firstFrame != nil }
        #expect(!asleepText.isEmpty)
        #expect(firstFrame == asleepText, "the woken tab's omnibar showed \(firstFrame.debugDescription), not its address")
    }

    /// The held address is not stale: once the woken page reports another real address (a
    /// redirect, a link), the omnibar shows it.
    @Test func aWokenTabThatMovesOnShowsItsNewAddress() async throws {
        let wake = try await ChromiumWake()
        defer { wake.rig.close() }
        _ = try await wake.show()
        let page = try #require(wake.made)
        let next = try #require(URL(string: "https://example.com/next"))
        let id = page.makeNavigationID()
        page.simulate(.started(id, url: next))
        page.simulate(.committed(id, url: next))
        try await wake.rig.until("the omnibar follows the page") { wake.bar.displayedText.contains("example.com/next") }
        #expect(wake.bar.displayedText != wake.asleepText)
    }

    /// A hibernated Chromium tab in the rig's app, woken onto a mock Chromium page that reports
    /// `about:blank` before its history comes back (no Chromium in the test process).
    @MainActor final class ChromiumWake {
        let rig: HiddenPageHibernationTests.Rig
        let key: String
        let asleepText: String
        private(set) var made: MockBrowserTab?
        var bar: AddressBarView { rig.services.cache.existingBrowser(key)!.chrome.addressBar }

        init() async throws {
            let rig = try HiddenPageHibernationTests.Rig()
            let key = try await rig.hide(rig.page("asleep", body: "<p>asleep</p>"))
            try await rig.until("the page hibernated") { rig.isHibernated(key) }
            let cache = rig.services.cache
            let webKit = try #require(cache.existingBrowser(key)?.tab as? HibernatedBrowserTab)
            let asleep = HibernatedBrowserTab(id: webKit.id, engine: .cef, profile: webKit.profileID, state: webKit.state,
                                              favicon: nil, restoreState: .chromium("saved"), snapshot: { nil })
            asleep.onWake = webKit.onWake
            cache.swapPage(key, with: asleep)
            self.rig = rig
            self.key = key
            asleepText = cache.existingBrowser(key)?.chrome.addressBar.displayedText ?? ""
            cache.makeCEFTab = { [weak self] configuration in
                let page = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
                page.simulate(.urlChanged(URL(string: "about:blank")))
                self?.made = page
                return page
            }
        }

        /// Shows the tab and returns the omnibar's text in the turn the woken page replaced the placeholder.
        func show() async throws -> String {
            let cache = rig.services.cache
            var firstFrame: String?
            let key = key
            cache.onBrowserReady = { [weak cache] ready in
                guard ready == key, firstFrame == nil, !(cache?.existingBrowser(ready)?.tab is HibernatedBrowserTab) else { return }
                firstFrame = cache?.existingBrowser(ready)?.chrome.addressBar.displayedText
            }
            cache.present(key, by: rig.pane, presence: .visible)
            try await rig.until("the page woke") { firstFrame != nil }
            return firstFrame ?? ""
        }
    }
}
