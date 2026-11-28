import AppKit
public import CmuxNextBrowser
public import CmuxNextTabs
import CmuxNextWakeups
public import Foundation
public import Observation

/// Favicons for tab strips, per browser profile: the live page's icon or,
/// for a tab without a live page (not yet shown, hibernated, in another
/// window), the one its daemon record names.
///
/// Reading `image(for:profile:)` inside an observed scope (a strip
/// snapshot) starts one fetch for an icon it does not have and re-renders
/// that scope when the icon arrives: no polling. A live page's icon is fetched
/// as that page fetches it (a Chromium tab through its own request context);
/// others go through `BrowserFaviconLoader` (http(s) only, no cookies, 1 MiB
/// cap, per-profile cache, shared with the engines' own fetches). A failed URL is not
/// fetched again for ``failureMemory``, doubling for each failure in a row up to
/// ``longestFailureMemory`` (a site with no icon is not fetched every minute); when that ends, the scopes that read it re-render and
/// fetch it again (one failure, offline at launch or a timeout, kept a site's globe for the
/// session, #42435). Failures end in batches, one timer per backoff step (``FailureBatch``): 500 pages with no icon
/// wake the app once a minute at most, not 500 times, each time mapping every row again.
@MainActor
@Observable
public final class TabFaviconStore {
    private struct Key: Hashable {
        var profile: BrowserProfileID
        var url: URL
    }

    /// Icons per profile and URL. `TabImage` identity is stable per entry,
    /// so a strip redraws an icon only when it changes.
    private var images = LRUCache<Key, TabImage>(capacity: 256)
    /// Counts landed icons: a reader outside an observed strip (Search Tabs, the bookmarks
    /// bars) re-reads when it moves.
    public private(set) var revision = 0
    /// One fetch per missing icon; each ends on its own (the loader's timeout).
    @ObservationIgnored private var pending: [Key: Task<Void, Never>] = [:]
    /// Failed URLs, each until its ``failureMemory`` ends.
    @ObservationIgnored private var failed: Set<Key> = []
    /// Counts ended batches of failures. Observed: a scope that read a missing icon re-renders when a batch ends,
    /// and that read fetches the icons whose failure ended. One write per batch: a failure and its end write
    /// nothing else observed, so 500 failed icons do not map every reading scope 500 times.
    private var forgotten = 0
    /// The failures waiting to end, per backoff step (0 is one ``failureMemory``).
    @ObservationIgnored private var batches: [Int: FailureBatch] = [:]
    /// Failures in a row per URL, for the backoff; a landed icon clears its count.
    @ObservationIgnored private var failures = LRUCache<Key, Int>(capacity: 4096)
    /// Icons a page's own fetch put in the loader's cache, as this store hands them out (`adopt`), with the
    /// loader's image each came from: one stable `TabImage` per icon, made without writing observed state.
    @ObservationIgnored private var adopted = LRUCache<Key, (source: NSImage, image: TabImage)>(capacity: 256)
    @ObservationIgnored private let loader: any BrowserFaviconLoading
    /// The last good icon of each site origin: a page's face never goes back to the globe once its site's icon was known.
    @ObservationIgnored public let kept: OriginFaviconKeeper
    /// Times the failure memory (a test moves its own).
    @ObservationIgnored private let clock: any Clock<Duration>

    /// How long a failed icon is not fetched again (#42435).
    public static let failureMemory: Duration = .seconds(60)
    /// The longest a URL that keeps failing is held off.
    public static let longestFailureMemory: Duration = .seconds(30 * 60)

    /// How long a URL is held off after `count` failures in a row, at least: its failure ends with its step's batch,
    /// at most this much later.
    public static func failureMemory(after count: Int) -> Duration {
        min(failureMemory * (1 << step(after: count)), longestFailureMemory)
    }

    /// The backoff step of `count` failures in a row.
    private static func step(after count: Int) -> Int { min(max(count - 1, 0), 5) }

    /// The failures of one backoff step: `ending` end when `timer` fires, `next` (failed while it ran) one
    /// memory after that, so no failure ends early and a step wakes the app once per memory at most.
    private struct FailureBatch {
        let timer: DemandTimer
        var ending: [Key] = []
        var next: [Key] = []
    }

    /// Creates a favicon store over the supplied loader.
    ///
    /// - Parameters:
    ///   - loader: the browser favicon loader used for pages without a live tab.
    ///   - clock: times the failure memory.
    ///   - originDirectory: where each site origin's last good icon persists (``OriginFaviconKeeper``); nil keeps them in memory.
    public init(loader: any BrowserFaviconLoading, clock: any Clock<Duration> = ContinuousClock(), originDirectory: URL? = nil) {
        self.loader = loader
        self.clock = clock
        kept = OriginFaviconKeeper(directory: originDirectory)
        kept.onLoaded = { [weak self] in self?.revision += 1 }
    }

    /// ``image(for:profile:tab:)`` for a page at `page` (or `origin`, `https://host[:port]`), which never answers nil for a
    /// site whose icon was known (an in-site navigation, a reload, a fetch that failed or is still out, a cold start, a
    /// tab made again): the origin's last good icon stands in until a new one arrives. `persist` off for an incognito tab.
    /// `fetching` off reads only what is here (a list of every bookmark must not fetch every site's icon).
    public func face(for address: String?, profile: BrowserProfileID, tab: (any BrowserTab)? = nil, page: URL? = nil,
                     origin: String? = nil, persist: Bool = true, fetching: Bool = true) -> TabImage? {
        let fresh = fetching ? image(for: address, profile: profile, tab: tab) : address.flatMap { cachedImage(for: $0, profile: profile) }
        return kept.face(fresh: fresh, origin: origin ?? OriginFaviconKeeper.origin(of: page), profile: profile, persist: persist,
                         keeps: OriginFaviconKeeper.keeps(tab))
    }

    /// The icon at `address` for a page of `profile`, or nil while it loads
    /// (the caller shows a globe) or when there is none. `tab`, the live page the icon is
    /// for, fetches it as that page would (a Chromium tab through its own request context).
    public func image(for address: String?, profile: BrowserProfileID, tab: (any BrowserTab)? = nil) -> TabImage? {
        guard let address, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        let key = Key(profile: profile, url: url)
        if let image = images.peek(key) ?? adopt(key, tab: tab) { return image }
        load(key, tab: tab)
        return nil
    }

    /// The icon a page already fetched for `key` (its engine's own fetch, kept in the loader's cache), taken
    /// without a second fetch, also while `key`'s failure is remembered: another page of the site (a Spotify
    /// album after the home page's fetch failed) loaded it, so its row and strip item show it now and not when
    /// the failure memory ends (#42435). Reading the live page's `favicon` maps the reading scope again when that
    /// page's own fetch lands. A read writes nothing observed (no other scope maps again in the middle of an
    /// update): the icon is kept in ``adopted``, and the held-off address keeps its failure until its memory ends.
    private func adopt(_ key: Key, tab: (any BrowserTab)?) -> TabImage? {
        _ = tab?.favicon
        guard let icon = loader.cachedFavicon(at: key.url, profile: key.profile) else { return nil }
        if let kept = adopted.peek(key), kept.source === icon { return kept.image }
        guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let image = TabImage(cgImage)
        adopted.set((icon, image), for: key)
        return image
    }

    /// The icon at `address` for `profile` when it is already here; never fetches (a list
    /// of every bookmark must not fetch every site's icon).
    public func cachedImage(for address: String, profile: BrowserProfileID) -> TabImage? {
        URL(string: address).flatMap { images.peek(Key(profile: profile, url: $0)) }
    }

    /// True while the icon at `address` for `profile` is being fetched.
    public func isFetching(_ address: String, profile: BrowserProfileID) -> Bool {
        guard let url = URL(string: address) else { return false }
        return pending[Key(profile: profile, url: url)] != nil
    }

    private func load(_ key: Key, tab: (any BrowserTab)?) {
        // Read even while a fetch is in flight: a scope that met this fetch re-renders when its failure memory ends.
        _ = forgotten
        guard !failed.contains(key), pending[key] == nil else { return }
        pending[key] = Task { [weak self, weak tab, loader] in
            let icon: NSImage?
            if let tab { icon = await tab.fetchFavicon(key.url) } else { icon = await loader.favicon(at: key.url, profile: key.profile) }
            guard let self else { return }
            self.pending[key] = nil
            if let cgImage = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.images.set(TabImage(cgImage), for: key)
                self.failures.removeAll { $0 == key }
                self.revision += 1
            } else {
                self.remember(failed: key)
            }
        }
    }

    /// Holds `key` off for its failure memory (``failureMemory(after:)``), then lets the next read fetch it again.
    private func remember(failed key: Key) {
        failed.insert(key)
        let count = (failures.peek(key) ?? 0) + 1
        failures.set(count, for: key)
        let step = Self.step(after: count)
        guard var batch = batches[step] else {
            batches[step] = FailureBatch(timer: DemandTimer(owner: "TabFaviconStore.failureMemory", clock: clock), ending: [key])
            return arm(step)
        }
        batch.next.append(key)
        batches[step] = batch
    }

    private func arm(_ step: Int) {
        batches[step]?.timer.schedule(after: Self.failureMemory(after: step + 1)) { @MainActor [weak self] in self?.forget(step) }
    }

    /// Ends the failures of `step` whose memory is over, in one observed write, and times the ones that came after.
    private func forget(_ step: Int) {
        guard var batch = batches[step] else { return }
        failed.subtract(batch.ending)
        forgotten += 1
        batch.ending = batch.next
        batch.next = []
        batches[step] = batch.ending.isEmpty ? nil : batch
        arm(step)
    }
}
