import AppKit
public import CmuxNextBrowser
import CmuxNextCompat
public import CmuxNextTabs
import CryptoKit
public import Foundation
import ImageIO
public import Observation
import UniformTypeIdentifiers

/// The last good favicon of each site origin (`https://host[:port]`) per browser profile, in memory and on disk, so
/// a browser tab never goes back to the globe once its site's icon was known (Leo 2026-11-22: "why do the favicons
/// keep turning into globes after stuff?"). A tab's own icon address goes nil or loads again after an in-site
/// navigation, a reload, a fetch failure, a hibernate and wake, a pane move, a relaunch or an update with a cold
/// memory cache; each of those showed the globe until the new icon arrived. A reader asks here when its fresh read
/// is nil and keeps showing what the origin last had; the origin's own new icon replaces it, a different origin with
/// no icon yet has none (the globe), and an incognito profile's icons are never written to disk.
///
/// Reading ``kept(origin:profile:)`` inside an observed scope registers ``revision``: a disk read that lands moves it,
/// so a cold start's scopes map again with the icon. ``keep(_:origin:profile:persist:)`` writes nothing observed (a
/// read path calls it, and no other scope may map again in the middle of an update).
@MainActor
@Observable
public final class OriginFaviconKeeper {
    private struct Key: Hashable {
        var profile: BrowserProfileID
        var origin: String
    }

    /// Counts disk reads that landed an icon.
    public private(set) var revision = 0
    @ObservationIgnored private var memory = LRUCache<Key, TabImage>(capacity: 512)
    /// Origins whose disk file was already asked for (a miss included): one read each per launch.
    @ObservationIgnored private var asked: Set<Key> = []
    /// What was last written to disk per key, so an unchanged icon is not rewritten.
    @ObservationIgnored private var written = LRUCache<Key, TabImage>(capacity: 512)
    @ObservationIgnored private let directory: URL?
    /// Runs when a disk read lands an icon (the store moves its own ``TabFaviconStore/revision``).
    @ObservationIgnored var onLoaded: @MainActor () -> Void

    /// - Parameters:
    ///   - directory: where icons persist (one folder per profile); nil keeps them in memory only.
    ///   - onLoaded: called after a disk read landed an icon.
    public init(directory: URL?, onLoaded: @escaping @MainActor () -> Void = {}) {
        self.directory = directory
        self.onLoaded = onLoaded
    }

    /// The icon `origin` last had for `profile`, or nil. A miss asks the disk once (off the main thread).
    public func kept(origin: String, profile: BrowserProfileID) -> TabImage? {
        _ = revision
        let key = Key(profile: profile, origin: origin)
        if let image = memory.peek(key) { return image }
        loadFromDisk(key)
        return nil
    }

    /// Remembers `image` as `origin`'s icon for `profile`; written to disk when `persist` (never for an incognito tab).
    public func keep(_ image: TabImage, origin: String, profile: BrowserProfileID, persist: Bool) {
        let key = Key(profile: profile, origin: origin)
        guard memory.peek(key) !== image else { return }
        memory.set(image, for: key)
        asked.insert(key)
        guard persist, written.peek(key) !== image, let file = file(for: key) else { return }
        written.set(image, for: key)
        let cgImage = image.cgImage
        Task.detached(priority: .utility) { Self.write(cgImage, to: file) }
    }

    private func loadFromDisk(_ key: Key) {
        guard let file = file(for: key), asked.insert(key).inserted else { return }
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { Self.read(file) }.value
            guard let self, let loaded, self.memory.peek(key) == nil else { return }
            let image = TabImage(loaded)
            self.memory.set(image, for: key)
            self.written.set(image, for: key)
            self.revision += 1
            self.onLoaded()
        }
    }

    private func file(for key: Key) -> URL? {
        directory.map { Self.file(in: $0, profile: key.profile, origin: key.origin) }
    }

    private nonisolated static func file(in directory: URL, profile: BrowserProfileID, origin: String) -> URL {
        let name = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: profile.rawValue.uuidString, directoryHint: .isDirectory)
            .appending(path: name + ".png", directoryHint: .notDirectory)
    }

    private nonisolated static func write(_ image: CGImage, to file: URL) {
        guard (try? FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).blockingWrite(to: file, options: .atomic)
    }

    private nonisolated static func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The one rule every reader of a page's favicon follows: the fresh icon when there is one (and it becomes the
/// origin's kept icon), else the origin's last good icon, else nil (the globe) for an origin that never had one.
extension OriginFaviconKeeper {
    /// `https://host[:port]` of `page`, the key a site's icon is kept under (nil for an address without a host).
    public nonisolated static func origin(of page: URL?) -> String? {
        guard let page, let scheme = page.scheme?.lowercased(), let host = page.host()?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (page.port.map { ":\($0)" } ?? "")
    }

    /// ``face(fresh:origin:profile:persist:keeps:)`` for the page at `page`.
    public func face(fresh: TabImage?, page: URL?, profile: BrowserProfileID, persist: Bool, keeps: Bool = true) -> TabImage? {
        face(fresh: fresh, origin: Self.origin(of: page), profile: profile, persist: persist, keeps: keeps)
    }

    /// `keeps` off while the page's address and its icon may belong to different documents (a navigation not committed
    /// yet: the address is the new site's, the icon still the old one's), so one origin's icon is never kept for another.
    public func face(fresh: TabImage?, origin: String?, profile: BrowserProfileID, persist: Bool, keeps: Bool = true) -> TabImage? {
        guard let origin else { return fresh }
        if let fresh {
            if keeps { keep(fresh, origin: origin, profile: profile, persist: persist) }
            return fresh
        }
        return kept(origin: origin, profile: profile)
    }

    /// Whether `tab`'s address and icon belong to one committed document (the icon may be kept for its origin).
    public static func keeps(_ tab: (any BrowserTab)?) -> Bool {
        guard let tab else { return true }
        switch tab.state.phase {
        case .committed, .finished: return true
        case .idle, .provisional, .failed: return false
        }
    }
}
