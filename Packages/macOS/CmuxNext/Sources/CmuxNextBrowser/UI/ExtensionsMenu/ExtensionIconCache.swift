import AppKit
import CmuxNextCompat
import CmuxNextIcons
import CmuxNextWakeups

// memory: fixed: one entry per installed extension listed in the bubble (its icon path, else its
// toolbar PNG; an update replaces the extension's folder), each decoded at 2 x `side` on its longer
// side, 40 x 40 x 4 = 6.4 KB at the standard 20 pt; it lives in the pane's Extensions bubble
// controller, made only once the bubble opens.
/// Extension icons for the Extensions bubble, read and decoded once per file, off the main thread,
/// at the size the bubble draws them. Chromium writes an extension's icons under a folder named for
/// its version, so a path names one image for as long as the extension stays installed; an update
/// brings a new path. A row shows Chrome's puzzle piece until its icon arrives; the icons one render
/// asks for are read in one lane item, and their arrival calls ``onLoad`` once, as Chrome's
/// `ImageLoader::LoadImagesAsync` decodes a set of images on its thread pool and replies to the UI
/// thread once (extensions/browser/image_loader.cc).
@MainActor
final class ExtensionIconCache {
    /// What an icon is read from: the bundled file, else the toolbar's PNG.
    private nonisolated enum Key: Hashable, Sendable {
        case file(String)
        case png(Data)
    }

    /// One icon to read and decode.
    private nonisolated struct Request: Sendable {
        let key: Key
        let path: String?
        let png: Data?
    }

    private var images: [Key: NSImage] = [:]
    /// Icons being decoded, so a re-render while one is on its way asks for it once.
    private var requested: Set<Key> = []
    /// Bumped by ``removeAll()``: a decode asked for before it does not land.
    private var generation: UInt64 = 0
    private let side: CGFloat
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    /// Runs when icons arrived (the bubble re-renders its rows in place).
    var onLoad: (() -> Void)?
    /// Files asked for (a test seam: a second open reads none).
    private(set) var loads = 0

    /// `work` reads and decodes the icons; `mainWork` takes them back to the main thread.
    init(side: CGFloat = ExtensionsMenuStyle.standard.extensionIcon, work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.side = side
        self.work = work
        self.mainWork = mainWork
    }

    /// Drops every decoded icon (the bubble's rows went); the next render decodes them again.
    func removeAll() {
        images.removeAll()
        requested.removeAll()
        generation &+= 1
    }

    /// The icon of each of `infos`, in order: its bundled icon (its largest up to 128 pixels), else its
    /// toolbar icon in `pngs` (by extension id), else Chrome's puzzle piece named for VoiceOver. An
    /// icon not decoded yet shows the puzzle piece; the ones asked for the first time start one lane item.
    func images(for infos: [BrowserExtensionInfo], pngs: [String: Data?]) -> [NSImage] {
        var batch: [Request] = []
        let shown = infos.map { info -> NSImage in
            let png = pngs[info.id] ?? nil
            guard let key = info.iconPath.map(Key.file) ?? png.map(Key.png) else { return fallback(name: info.name) }
            if let cached = images[key] { return cached }
            if requested.insert(key).inserted { batch.append(Request(key: key, path: info.iconPath, png: png)) }
            return fallback(name: info.name)
        }
        load(batch)
        return shown
    }

    private func load(_ batch: [Request]) {
        guard !batch.isEmpty else { return }
        loads += batch.count(where: { $0.path != nil })
        let pixels = Int(side * 2), generation = self.generation
        work.run(.userVisible, mayBlock: .files) { batch.map { ($0.key, Self.decode($0, pixels: pixels)) } }
            .reply(on: mainWork, class: .visible, owner: "ExtensionIconCache.loaded") { [weak self] decoded in
                self?.loaded(decoded, generation: generation)
            }
    }

    private func loaded(_ decoded: [(Key, CGImage?)], generation: UInt64) {
        guard generation == self.generation else { return }
        // A file that does not decode stays requested: its row keeps the puzzle piece until the
        // extension changes (a new path) or the rows go.
        var arrived = false
        for case let (key, bitmap?) in decoded {
            images[key] = IconAssetDecode.image(bitmap, points: side)
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
