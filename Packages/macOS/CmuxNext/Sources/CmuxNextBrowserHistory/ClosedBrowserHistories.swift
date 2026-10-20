public import CmuxNextBrowser
public import CmuxNextDaemon
public import Foundation

/// Reopen Closed Tab brings back a browser tab's back/forward history
/// (cx-d0d.59), as Chrome's Cmd-Shift-T does. The daemon's closed record
/// keeps a tab's URL, not its history, so the App keeps the history each
/// closing page saves (the state hibernation saves) for as many closes as
/// the daemon keeps. A reopen hands the newest history saved at each closed
/// tab's URL to the page the reopened tab gets: a WebKit page is made
/// restored (`BrowserPageRequests.takeAdoption`), a Chromium page gets it
/// as its `restoreState` (`restoring`, through `configureBrowser`). A
/// history no page claims within a minute is dropped; that tab loads its
/// URL as before. Only local reopens restore, into a page of the profile
/// the history closed in. The daemon's copy of the history (cx-d0d.11, for
/// a reopen after a relaunch) is then not applied on top of it.
@MainActor
public final class ClosedBrowserHistories {
    private struct Saved {
        var url: String
        var profile: BrowserProfileID
        var state: BrowserRestoreState
        var at: ContinuousClock.Instant
    }

    /// The daemon keeps the newest 50 closed items (`ClosedItem`).
    static let limit = 50
    private static let claimWindow = Duration.seconds(60)
    private let clock = ContinuousClock()
    /// Closed pages' histories, oldest first.
    private var closed: [Saved] = []
    /// Histories of tabs a reopen is recreating, until their pages claim them.
    private var expected: [Saved] = []
    /// Tabs whose new page restored a history from here, with the engine
    /// it restored in.
    private var restoredTabs: [String: BrowserEngineKind] = [:]

    public init() {}

    /// A browser tab's page is closing (`TabContentCache.release`).
    public func save(_ page: (any BrowserTab)?) {
        guard let page, let url = page.state.url?.absoluteString, let state = BrowserRestoreState.history(of: page) else { return }
        closed.append(Saved(url: url, profile: page.profileID, state: state, at: clock.now))
        if closed.count > Self.limit { closed.removeFirst(closed.count - Self.limit) }
    }

    /// `item` is about to reopen: each of its browser tabs' newest saved
    /// history waits for the tab's new page.
    public func expect(_ item: ClosedItem) {
        let now = clock.now
        expected.removeAll { now - $0.at > Self.claimWindow }
        for tab in item.tabs where tab.kind == "browser" {
            guard let url = tab.url, let index = closed.lastIndex(where: { $0.url == url }) else { continue }
            var saved = closed.remove(at: index)
            saved.at = now
            expected.append(saved)
        }
    }

    /// `item`'s reopen failed: its histories wait no longer.
    public func drop(_ item: ClosedItem) {
        let urls = Set(item.tabs.compactMap(\.url))
        expected.removeAll { urls.contains($0.url) }
    }

    /// The history a reopened tab's new page at `url` in `profile` restores,
    /// for a Chromium page or a WebKit one.
    public func claim(_ url: String?, profile: BrowserProfileID, chromium: Bool, tab: String) -> BrowserRestoreState? {
        let now = clock.now
        guard let url, let index = expected.lastIndex(where: {
            $0.url == url && $0.profile == profile && now - $0.at <= Self.claimWindow && Self.isChromium($0.state) == chromium
        }) else { return nil }
        restoredTabs[tab] = chromium ? .cef : .webkit
        return expected.remove(at: index).state
    }

    /// True once when tab `tab`'s page in `engine` restored a history from
    /// here; a Chromium page that failed to start and fell back to WebKit did not.
    public func takeRestored(_ tab: String, engine: BrowserEngineKind) -> Bool {
        restoredTabs.removeValue(forKey: tab) == engine
    }

    /// `base` for a new Chromium page at `url`, with a reopened local tab's
    /// history when one waits for it; a page that already restores keeps its own.
    public func restoring(_ base: BrowserTabConfiguration, url: URL?, local: Bool, tab: String) -> BrowserTabConfiguration {
        guard local, base.restoreState == nil,
              let state = claim(url?.absoluteString, profile: base.profile, chromium: true, tab: tab) else { return base }
        var restored = base
        restored.restoreState = state
        return restored
    }

    private static func isChromium(_ state: BrowserRestoreState) -> Bool {
        if case .chromium = state { true } else { false }
    }
}
