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
    /// Each icon's inline image (``dataURL(_:)``), by icon identity, least recently used out. The
    /// entry holds its icon weakly: a full-size icon the `images` cache dropped is not kept alive
    /// for an identity check, and an identifier reused by a later icon finds the entry dead.
    @ObservationIgnored private var dataURLs = LRUCache<ObjectIdentifier, InlinedIcon>(capacity: 256)
    @ObservationIgnored private let encode: (CGImage) -> Data?

    /// - Parameters:
    ///   - loader: Fetches an icon no live page fetches.
    ///   - encode: An icon's PNG bytes for ``dataURL(_:)`` (tests count its calls).
    init(loader: any BrowserFaviconLoading = BrowserFaviconLoader.shared, encode: @escaping (CGImage) -> Data? = TabFaviconStore.png) {
        self.loader = loader
        self.encode = encode
    }

    /// `image` as the inline image a cmux page may draw (its CSP allows `img-src data:` only),
    /// encoded once per icon and at the size the page draws it (``inlined(_:)``): a New Tab
    /// page, built on the key's turn of every Cmd-T and Cmd-N, lists every open browser tab's
    /// icon and up to 40 recent pages' icons, and its context (these images included) is
    /// encoded and sent into the page in that turn. An icon's `TabImage` is the same object
    /// while it is cached, so its encoding is too.
    func dataURL(_ image: TabImage?) -> String? {
        guard let image else { return nil }
        if let known = dataURLs.value(for: ObjectIdentifier(image)), known.image === image { return known.url }
        guard let png = encode(Self.inlined(image.cgImage)) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        dataURLs.set(InlinedIcon(image: image, url: url), for: ObjectIdentifier(image))
        return url
    }

    /// `image`'s PNG bytes.
    nonisolated static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The long side, in pixels, of an icon a cmux page draws: its 16 pt icon box (the New Tab
    /// page's `.nt-row-glyph`) at 2x.
    nonisolated static let inlinePixels = 32

    /// `image` with its long side at most ``inlinePixels``, its shape kept; a smaller image as it
    /// is. A site serves its icon at any size (a 180 px touch icon, a 256 px `favicon.ico` layer;
    /// the loader allows 1 MiB), 10 to 100 times the bytes of the one drawn, and a page gets
    /// every listed icon on the key's turn of the create that opens it.
    nonisolated static func inlined(_ image: CGImage) -> CGImage {
        let long = max(image.width, image.height)
        guard long > inlinePixels else { return image }
        let scale = Double(inlinePixels) / Double(long)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
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

/// One icon's inline image in ``TabFaviconStore``'s data URL cache; the icon is held weakly.
private struct InlinedIcon {
    weak var image: TabImage?
    let url: String
}
