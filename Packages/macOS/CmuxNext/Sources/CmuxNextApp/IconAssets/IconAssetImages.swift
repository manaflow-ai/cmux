import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import ImageIO
import Observation
import CmuxNextIcons

/// Stored icon assets (`image:` / `svg:sha256-<hex>`) as images to draw. Each asset is read from
/// its owner once (`get-blob`), decoded off the main actor and kept; a reader observing
/// ``image(_:owner:)`` redraws when it arrives. An SVG is drawn as an isolated image, never
/// put into a page. Content addressed, so one decoded image serves every owner that names it.
///
/// Registered (``registerMemoryConsumer(with:)``), the decoded images are one lossless memory consumer: a
/// dropped image is read from its owner again the next time a reader asks for it. At most ``keep`` stay,
/// the oldest decode dropped first; a release drops down to the limit's share of ``keep``. A read that
/// lands under a lowered limit is still kept (a reader on screen asked for it now: its working set); the
/// next release takes it.
@MainActor @Observable
final class IconAssetImages {
    static let shared = IconAssetImages()

    /// Point size an asset is drawn for (sidebar and tab icons), rendered at ``scale``.
    nonisolated static let side: CGFloat = 32
    nonisolated static let scale: CGFloat = 2
    /// The most decoded assets kept: one 64 x 64 RGBA image (16 KiB) each, 16 MiB at most.
    nonisolated static let keep = 1024

    private var images: [String: SidebarFavicon] = [:]
    /// The keys of ``images``, oldest decode first.
    @ObservationIgnored private var order: [String] = []
    /// The pixel bytes of ``images``, kept on every insert and removal (the memory report).
    @ObservationIgnored private var imageBytes = 0
    /// How many images a release keeps: ``keep`` scaled by the memory coordinator's limit.
    @ObservationIgnored private var imageLimit = IconAssetImages.keep
    @ObservationIgnored private var memoryRegistration: MemoryConsumerRegistration?
    /// Assets being read, or answered but not drawable (a refused read, bytes that do not
    /// decode; never retried). A read whose transport failed (no connection yet, a timeout) is
    /// forgotten, so the next rebuild, such as the one a reconnect causes, reads it again.
    @ObservationIgnored private var requested: Set<String> = []
    /// The tab strip's wrapper of each image, kept: a strip compares tab images by identity.
    @ObservationIgnored private var tabImages: [String: TabImage] = [:]

    /// The image of asset icon `icon` (nil for an emoji or symbol, or until it is read).
    func image(_ icon: String, owner: DaemonService?) -> SidebarFavicon? {
        guard let value = IconValue(wire: icon), Self.isAsset(value) else { return nil }
        if let image = images[icon] { return image }
        guard !requested.contains(icon), let owner, owner.supports(DaemonCapability.iconAssets.rawValue),
              let connection = owner.connection else { return nil }
        requested.insert(icon)
        Task { [weak self] in
            let blob: (data: Data, mediaType: String)
            do {
                blob = try await IconAssetClient(connection).get(icon)
            } catch {
                // The owner's answer (no such asset) stands; a failed transport is retried.
                if case DaemonError.command? = error as? DaemonError { return }
                self?.requested.remove(icon)
                return
            }
            guard let image = await Self.decoded(blob.data, mediaType: blob.mediaType) else { return }
            self?.store(image, for: icon)
        }
        return nil
    }

    /// Keeps `image` as asset `icon`'s, dropping the oldest decodes past ``keep`` (tests store a decode directly).
    func store(_ image: SidebarFavicon, for icon: String) {
        if let old = images.updateValue(image, forKey: icon) {
            imageBytes -= Self.bytes(of: old)
        } else {
            order.append(icon)
        }
        imageBytes += Self.bytes(of: image)
        dropOldest(to: Self.keep, within: nil)
    }

    /// Drops the oldest decodes until at most `limit` stay or `slice` is spent. A dropped asset is
    /// forgotten as read, so the next reader reads it again.
    ///
    /// - Returns: Whether at most `limit` stay.
    @discardableResult
    private func dropOldest(to limit: Int, within slice: MemoryReleaseSlice?) -> Bool {
        var dropped = 0
        defer { order.removeFirst(dropped) }
        while order.count - dropped > max(limit, 0) {
            if slice?.isExpired == true { return false }
            let icon = order[dropped]
            dropped += 1
            if let image = images.removeValue(forKey: icon) { imageBytes -= Self.bytes(of: image) }
            tabImages[icon] = nil
            requested.remove(icon)
        }
        return true
    }

    private nonisolated static func bytes(of image: SidebarFavicon) -> Int {
        image.image.bytesPerRow * image.image.height
    }

    /// Registers the decoded images with the app's memory coordinator, one lossless consumer; a later
    /// call replaces the registration.
    ///
    /// - Parameter registry: The memory coordinator (injected).
    func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration?.cancel()
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// ``image(_:owner:)`` of `owner`'s assets as the sidebar mapping draws them.
    func sidebarIcon(owner: DaemonService) -> (String) -> SidebarFavicon? {
        { [weak owner] icon in self.image(icon, owner: owner) }
    }

    /// ``image(_:owner:)`` of `owner`'s assets as the tab and screen strips draw them.
    func tabIcon(owner: DaemonService) -> (String) -> TabImage? {
        { [weak owner] icon in
            guard let image = self.image(icon, owner: owner) else { return nil }
            if let cached = self.tabImages[icon], cached.cgImage === image.image { return cached }
            let tabImage = TabImage(image.image)
            self.tabImages[icon] = tabImage
            return tabImage
        }
    }

    /// ``image(_:owner:)`` of `owner`'s assets as an `NSImage` of `side` points (menus).
    func menuImage(_ icon: String?, owner: DaemonService?, side: CGFloat) -> NSImage? {
        guard let icon, let image = image(icon, owner: owner) else { return nil }
        return NSImage(cgImage: image.image, size: NSSize(width: side, height: side))
    }

    private static func isAsset(_ value: IconValue) -> Bool {
        switch value {
        case .image, .svg: true
        case .emoji, .symbol: false
        }
    }

    /// ``decode(_:mediaType:)`` off the main actor (`SidebarFavicon` carries the image back).
    @concurrent nonisolated static func decoded(_ data: Data, mediaType: String) async -> SidebarFavicon? {
        decode(data, mediaType: mediaType).map(SidebarFavicon.init)
    }

    /// One stored asset as an image of at most ``side`` points at ``scale``: an SVG (SVG text
    /// only) through `NSImage`, no page and no script, square with its aspect kept and centered;
    /// a raster only of the type its media type names, through ``IconAssetDecode``. A daemon on
    /// another computer is less trusted, so the bytes must be what the label says.
    nonisolated static func decode(_ data: Data, mediaType: String) -> CGImage? {
        let pixels = Int(side * scale)
        if mediaType == "image/svg+xml" {
            guard IconAssetDecode.isSVGText(data), let svg = blockingNSImage(data),
                  svg.size.width > 0, svg.size.height > 0 else { return nil }
            return draw(pixels: pixels, size: svg.size) { rect in
                svg.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        guard let type = IconAssetDecode.storedTypes[mediaType] else { return nil }
        return IconAssetDecode.thumbnail(data, types: [type], maxPixelSize: pixels)
    }

    private nonisolated static func draw(pixels: Int, size: CGSize, _ body: (CGRect) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let fit = min(CGFloat(pixels) / size.width, CGFloat(pixels) / size.height)
        let drawn = CGSize(width: size.width * fit, height: size.height * fit)
        let rect = CGRect(x: (CGFloat(pixels) - drawn.width) / 2, y: (CGFloat(pixels) - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body(rect)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// The decoded asset images as one lossless consumer (Chrome's consumer contract,
/// base/memory_coordinator/memory_consumer.h): a new limit frees nothing; ``releaseMemory(within:)``
/// drops the oldest decodes down to it. An image a strip or the sidebar still draws stays alive in
/// that view; only the cache forgets it.
extension IconAssetImages: MemoryConsumer {
    /// Up to ``keep`` small images (1 to 50 MB at most); dropping one touches only memory, and reading it
    /// again is a daemon round trip (a remote one over the network), so only critical pressure acts.
    nonisolated static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .expensive,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The consumer's name in the memory report.
    nonisolated static let memoryConsumerName = "icon-asset-images"

    func updateMemoryLimit(_ limit: MemoryLimit) {
        imageLimit = limit.scale(Self.keep)
    }

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        return dropOldest(to: imageLimit, within: slice) ? .done : .more
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: imageBytes, entries: images.count)
    }
}
