import AppKit
public import CmuxNextBrowser
public import CmuxNextTabs
import CmuxNextWakeups
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
/// session, #42435).
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
    /// Failed URLs, each until its ``failureMemory`` ends. Observed: a scope that read a failed
    /// icon re-renders when its failure ends, and that read fetches it again.
    private var failed: Set<Key> = []
    /// The end of each failure's memory.
    @ObservationIgnored private var forgetting: [Key: DemandTimer] = [:]
    /// Failures in a row per URL, for the backoff; a landed icon clears its count.
    @ObservationIgnored private var failures = LRUCache<Key, Int>(capacity: 256)
    @ObservationIgnored private let loader: any BrowserFaviconLoading
    /// Times the failure memory (a test moves its own).
    @ObservationIgnored private let clock: any Clock<Duration>

    /// How long a failed icon is not fetched again (#42435).
    public static let failureMemory: Duration = .seconds(60)
    /// The longest a URL that keeps failing is held off.
    public static let longestFailureMemory: Duration = .seconds(30 * 60)

    /// How long a URL is held off after `count` failures in a row.
    public static func failureMemory(after count: Int) -> Duration {
        min(failureMemory * (1 << min(max(count - 1, 0), 5)), longestFailureMemory)
    }

    /// Creates a favicon store over the supplied loader.
    ///
    /// - Parameters:
    ///   - loader: the browser favicon loader used for pages without a live tab.
    ///   - clock: times the failure memory.
    public init(loader: any BrowserFaviconLoading, clock: any Clock<Duration> = ContinuousClock()) {
        self.loader = loader
        self.clock = clock
    }

    /// The icon at `address` for a page of `profile`, or nil while it loads
    /// (the caller shows a globe) or when there is none. `tab`, the live page the icon is
    /// for, fetches it as that page would (a Chromium tab through its own request context).
    public func image(for address: String?, profile: BrowserProfileID, tab: (any BrowserTab)? = nil) -> TabImage? {
        guard let address, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        let key = Key(profile: profile, url: url)
        if let image = images.peek(key) { return image }
        load(key, tab: tab)
        return nil
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
        // `failed` first, read even while a fetch is in flight: a scope that met this fetch re-renders when it fails
        // and when its failure memory ends.
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
        let timer = forgetting[key] ?? DemandTimer(owner: "TabFaviconStore.failureMemory", clock: clock)
        forgetting[key] = timer
        timer.schedule(after: Self.failureMemory(after: count)) { @MainActor [weak self] in
            self?.forgetting[key] = nil
            self?.failed.remove(key)
        }
    }
}
