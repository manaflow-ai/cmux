import AppKit
import CmuxNextCompat
import CmuxNextIcons
import CmuxNextWakeups

// memory: fixed: one entry per extension listed in the bubble (its last decoded icon, from its icon
// path, else its toolbar PNG; an entry of an extension no longer listed goes at the next render),
// each decoded at 2 x `side` on its longer side, 40 x 40 x 4 = 6.4 KB at the standard 20 pt; it lives
// in the pane's Extensions bubble controller, made only once the bubble opens.
/// Extension icons for the Extensions bubble, read and decoded off the main thread, at the size the
/// bubble draws them, one per extension. Chromium writes an extension's icons under a folder named
/// for its version, so a path names one image for as long as the extension stays installed; an update
/// brings a new path, and an extension with no icon file shows its toolbar PNG, which changes with
/// its badge. A row shows Chrome's puzzle piece until its first icon arrives, and its last icon while
/// a new one decodes; the icons one render asks for are read in one lane item, and their arrival calls
/// ``onLoad`` once, as Chrome's `ImageLoader::LoadImagesAsync` decodes a set of images on its thread
/// pool and replies to the UI thread once (extensions/browser/image_loader.cc), and its
/// `ExtensionIconImage` keeps showing the image it has until the new one is loaded
/// (extensions/browser/extension_icon_image.cc).
@MainActor
final class ExtensionIconCache {
    /// Which image an extension's icon is: its bundled file, else its toolbar PNG.
    private nonisolated enum Version: Hashable, Sendable {
        case file(String)
        case png(Data)
    }

    /// One icon to read and decode.
    private nonisolated struct Request: Sendable {
        let id: String
        let version: Version
        let path: String?
        let png: Data?
    }

    /// Each extension's last decoded icon, and which version it is.
    private var icons: [String: (version: Version, image: NSImage)] = [:]
    /// The version on its way for each extension, so a re-render while it is decoding asks for it
    /// once. A version that did not decode stays here: its row keeps what it shows until the extension
    /// changes (a new path, a new PNG) or the rows go.
    private var requested: [String: Version] = [:]
    /// Bumped by ``removeAll()``: a decode asked for before it does not land.
    private var generation: UInt64 = 0
    private let side: CGFloat
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    /// Runs when icons arrived (the bubble re-renders its rows in place).
    var onLoad: (() -> Void)?
    /// Files asked for (a test seam: a second open reads none).
    private(set) var loads = 0
    /// Extensions with a decoded icon (a test seam: one per extension, whatever its versions).
    var count: Int { icons.count }

    /// `work` reads and decodes the icons; `mainWork` takes them back to the main thread.
    init(side: CGFloat = ExtensionsMenuStyle.standard.extensionIcon, work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.side = side
        self.work = work
        self.mainWork = mainWork
    }

    /// Drops every decoded icon (the bubble's rows went); the next render decodes them again.
    func removeAll() {
        icons.removeAll()
        requested.removeAll()
        generation &+= 1
    }

    /// The icon of each of `infos`, in order: its bundled icon (its largest up to 128 pixels), else its
    /// toolbar icon in `pngs` (by extension id), else Chrome's puzzle piece named for VoiceOver. While a
    /// new version decodes, the extension's last icon shows (the puzzle piece before its first); the
    /// versions asked for the first time start one lane item.
    func images(for infos: [BrowserExtensionInfo], pngs: [String: Data?]) -> [NSImage] {
        if icons.count > infos.count || requested.count > infos.count { forgetUnlisted(infos) }
        var batch: [Request] = []
        let shown = infos.map { info -> NSImage in
            let png = pngs[info.id] ?? nil
            guard let version = info.iconPath.map(Version.file) ?? png.map(Version.png) else { return fallback(name: info.name) }
            let decoded = icons[info.id]
            if let decoded, decoded.version == version { return decoded.image }
            if requested[info.id] != version {
                requested[info.id] = version
                batch.append(Request(id: info.id, version: version, path: info.iconPath, png: png))
            }
            return decoded?.image ?? fallback(name: info.name)
        }
        load(batch)
        return shown
    }

    /// Drops the icons and requests of extensions `infos` no longer lists (uninstalled, or out of the bubble).
    private func forgetUnlisted(_ infos: [BrowserExtensionInfo]) {
        let listed = Set(infos.map(\.id))
        icons = icons.filter { listed.contains($0.key) }
        requested = requested.filter { listed.contains($0.key) }
    }

    private func load(_ batch: [Request]) {
        guard !batch.isEmpty else { return }
        loads += batch.count(where: { $0.path != nil })
        let pixels = Int(side * 2), generation = self.generation
        work.run(.userVisible, mayBlock: .files) { batch.map { ($0.id, $0.version, Self.decode($0, pixels: pixels)) } }
            .reply(on: mainWork, class: .visible, owner: "ExtensionIconCache.loaded") { [weak self] decoded in
                self?.loaded(decoded, generation: generation)
            }
    }

    private func loaded(_ decoded: [(String, Version, CGImage?)], generation: UInt64) {
        guard generation == self.generation else { return }
        var arrived = false
        // An arrival of a version no longer asked for (a newer one came since, or the extension left) is stale.
        for case let (id, version, bitmap?) in decoded where requested[id] == version {
            icons[id] = (version, IconAssetDecode.image(bitmap, points: side))
            requested[id] = nil
            arrived = true
        }
        if arrived { onLoad?() }
    }

    /// The icon file of `request`, else its PNG, decoded at most `pixels` on its longer side. Runs on
    /// a lane thread (it reads a file).
    private nonisolated static func decode(_ request: Request, pixels: Int) -> CGImage? {
        if let path = request.path, let data = try? Data(blockingContentsOf: URL(fileURLWithPath: path)),
           let bitmap = IconAssetDecode.thumbnail(data, types: IconAssetDecode.bitmapTypes, maxPixelSize: pixels) {
            return bitmap
        }
        return request.png.flatMap { IconAssetDecode.thumbnail($0, types: IconAssetDecode.bitmapTypes, maxPixelSize: pixels) }
    }

    private func fallback(name: String) -> NSImage {
        let image = NSImage.icon(.browserToolbarExtensions, size: side)
        image.accessibilityDescription = name
        return image
    }
}
