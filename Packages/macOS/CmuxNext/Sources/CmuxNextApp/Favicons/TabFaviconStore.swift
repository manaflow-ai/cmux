import AppKit
import CmuxNextBrowser
import CmuxNextTabs
import Observation

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
/// fetched again until it leaves the small failure memory.
@Observable
final class TabFaviconStore {
    private struct Key: Hashable {
        var profile: BrowserProfileID
        var url: URL
    }

    /// Icons per profile and URL. `TabImage` identity is stable per entry,
    /// so a strip redraws an icon only when it changes.
    private var images = LRUCache<Key, TabImage>(capacity: 256)
    /// Counts landed icons: a reader outside an observed strip (Search Tabs, the bookmarks
    /// bars) re-reads when it moves.
    private(set) var revision = 0
    /// One fetch per missing icon; each ends on its own (the loader's timeout).
    @ObservationIgnored private var pending: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var failed = LRUCache<Key, Bool>(capacity: 256)
    @ObservationIgnored private let loader: any BrowserFaviconLoading

    init(loader: any BrowserFaviconLoading = BrowserFaviconLoader.shared) {
        self.loader = loader
    }

    /// The icon at `address` for a page of `profile`, or nil while it loads
    /// (the caller shows a globe) or when there is none. `tab`, the live page the icon is
    /// for, fetches it as that page would (a Chromium tab through its own request context).
    func image(for address: String?, profile: BrowserProfileID, tab: (any BrowserTab)? = nil) -> TabImage? {
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
    func cachedImage(for address: String, profile: BrowserProfileID) -> TabImage? {
        URL(string: address).flatMap { images.peek(Key(profile: profile, url: $0)) }
    }

    /// True while the icon at `address` for `profile` is being fetched.
    func isFetching(_ address: String, profile: BrowserProfileID) -> Bool {
        guard let url = URL(string: address) else { return false }
        return pending[Key(profile: profile, url: url)] != nil
    }

    private func load(_ key: Key, tab: (any BrowserTab)?) {
        guard pending[key] == nil, failed.peek(key) == nil else { return }
        pending[key] = Task { [weak self, weak tab, loader] in
            let icon: NSImage?
            if let tab { icon = await tab.fetchFavicon(key.url) } else { icon = await loader.favicon(at: key.url, profile: key.profile) }
            guard let self else { return }
            self.pending[key] = nil
            if let cgImage = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.images.set(TabImage(cgImage), for: key)
                self.revision += 1
            } else {
                self.failed.set(true, for: key)
            }
        }
    }
}
