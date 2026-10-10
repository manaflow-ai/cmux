import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Reopen Closed Tab brings back a browser tab's back/forward history
/// (cx-d0d.59), as Chrome's Cmd-Shift-T does. The daemon's closed record
/// keeps a tab's URL, not its history, so the App keeps the history each
/// closing page saves (the state hibernation saves) for as many closes as
/// the daemon keeps. A reopen hands the newest history saved at each closed
/// tab's URL to the page the reopened tab gets: a WebKit page is made
/// restored (`BrowserPageRequests.takeAdoption`), a Chromium page gets it
/// as its `restoreState` (`restoring`, through `configureBrowser`). A
/// history no page claims within a minute is dropped; that tab loads its
/// URL as before.
@MainActor
final class ClosedBrowserHistories {
    private struct Saved {
        var url: String
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

    /// A browser tab's page is closing (`TabContentCache.release`).
    func save(_ page: (any BrowserTab)?) {
        guard let page, let url = page.state.url?.absoluteString, let state = BrowserTabDuplicate.history(of: page) else { return }
        closed.append(Saved(url: url, state: state, at: clock.now))
        if closed.count > Self.limit { closed.removeFirst(closed.count - Self.limit) }
    }

    /// `item` is about to reopen: each of its browser tabs' newest saved
    /// history waits for the tab's new page.
    func expect(_ item: ClosedItem) {
        let now = clock.now
        expected.removeAll { now - $0.at > Self.claimWindow }
        for tab in item.tabs where tab.kind == "browser" {
            guard let url = tab.url, let index = closed.lastIndex(where: { $0.url == url }) else { continue }
            var saved = closed.remove(at: index)
            saved.at = now
            expected.append(saved)
        }
    }

    /// The history a reopened tab's new page at `url` restores, for a
    /// Chromium page or a WebKit one.
    func claim(_ url: String?, chromium: Bool) -> BrowserRestoreState? {
        let now = clock.now
        guard let url, let index = expected.lastIndex(where: {
            $0.url == url && now - $0.at <= Self.claimWindow && Self.isChromium($0.state) == chromium
        }) else { return nil }
        return expected.remove(at: index).state
    }

    /// `base` for a new Chromium page at `url`, with a reopened tab's
    /// history when one waits for it; a page that already restores keeps its own.
    func restoring(_ base: BrowserTabConfiguration, url: URL?) -> BrowserTabConfiguration {
        guard base.restoreState == nil, let state = claim(url?.absoluteString, chromium: true) else { return base }
        var restored = base
        restored.restoreState = state
        return restored
    }

    private static func isChromium(_ state: BrowserRestoreState) -> Bool {
        if case .chromium = state { true } else { false }
    }
}
