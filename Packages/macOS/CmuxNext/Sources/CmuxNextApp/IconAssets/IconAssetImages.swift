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
import CmuxNextWakeups

/// Stored icon assets (`image:` / `svg:sha256-<hex>`) as images to draw. Each asset is read from
/// its owner once (`get-blob`), decoded off the main actor and kept; a reader observing
/// ``image(_:owner:)`` redraws when that asset arrives. Each asset is observed on its own, so a
/// reader is told about the assets it read only. An SVG is drawn as an isolated image, never
/// put into a page. Content addressed, so one decoded image serves every owner that names it.
///
/// Registered (``registerMemoryConsumer(with:)``), the decoded images are one lossless memory consumer,
/// evicted least recently used first, as Chrome's image decode caches are
/// (cc/tiles/software_image_decode_cache.cc on base/containers/lru_cache.h). At most ``keep`` stay. A release
/// drops down to the limit's share of ``keep``, but never a decode read in the last ``inUse``: a mapping
/// drawing now uses it, and Chrome never purges a decode in use. Forgetting a decode tells no reader: the
/// strips and the sidebar keep drawing the image they hold, and the next time one maps that icon again it
/// reads it from its owner again. A read that lands under a lowered limit is still kept (a reader asked for
/// it now); a later release takes it once it is no longer in use.
@MainActor @Observable
final class IconAssetImages {
    static let shared = IconAssetImages()

    /// Point size an asset is drawn for (sidebar and tab icons), rendered at ``scale``.
    nonisolated static let side: CGFloat = 32
    nonisolated static let scale: CGFloat = 2
    /// The most decoded assets kept: one 64 x 64 RGBA image (16 KiB) each, 16 MiB at most.
    nonisolated static let keep = 1024
    /// How long after its last read (or its arrival) a decode is in use, which a release keeps.
    nonisolated static let inUse: Duration = .seconds(1)

    /// Where an asset's bytes are read from: its owner daemon's `get-blob` (tests read from their own).
    struct Source {
        /// The stored bytes of an asset icon value and their media type.
        let read: @Sendable (_ icon: String) async throws -> (data: Data, mediaType: String)

        /// `owner`'s icon asset store; nil when there is no owner, or it does not store icon assets or is not connected.
        init?(owner: DaemonService?) {
            guard let owner, owner.supports(DaemonCapability.iconAssets.rawValue), let connection = owner.connection else { return nil }
            let client = IconAssetClient(connection)
            read = { icon in try await client.get(icon) }
        }

        init(read: @escaping @Sendable (_ icon: String) async throws -> (data: Data, mediaType: String)) {
            self.read = read
        }
    }

    /// One asset, observed on its own. Forgetting it removes the slot without writing `image`, so no
    /// reader is told; a later read makes a new slot.
    @MainActor @Observable
    final class Slot {
        fileprivate(set) var image: SidebarFavicon?
        /// The use order of the last read or arrival (higher is more recent): the LRU order.
        @ObservationIgnored fileprivate var lastUse: UInt64 = 0
        /// When it was last read or arrived, on the cache's clock.
        @ObservationIgnored fileprivate var usedAt: Duration = .zero
        /// The tab strip's wrapper of `image`, kept: a strip compares tab images by identity.
        @ObservationIgnored fileprivate var tabImage: TabImage?
    }

    /// Every asset a reader asked for, decoded or not yet; only decoded ones are ever forgotten.
    @ObservationIgnored private var slots: [String: Slot] = [:]
    /// How many slots hold an image.
    @ObservationIgnored private var decodedCount = 0
    /// The pixel bytes of the slots' images, kept on every insert and removal (the memory report).
    @ObservationIgnored private var imageBytes = 0
    /// The next use order (``Slot/lastUse``).
    @ObservationIgnored private var nextUse: UInt64 = 1
    /// How many images a release keeps: ``keep`` scaled by the memory coordinator's limit.
    @ObservationIgnored private var imageLimit = IconAssetImages.keep
    @ObservationIgnored private var memoryRegistration: MemoryConsumerRegistration?
    /// The time since the cache was made, on its clock.
    private let elapsed: () -> Duration
    /// Assets being read, or answered but not drawable (a refused read, bytes that do not
    /// decode; never retried). A read whose transport failed (no connection yet, a timeout) is
    /// forgotten, so the next rebuild, such as the one a reconnect causes, reads it again.
    @ObservationIgnored private var requested: Set<String> = []
    /// Where a read's arrival is posted (p06 recipe R-hop: the read and the decode run off main, the arrival is one
    /// posted task). The composition root attaches the app's scheduler (``attach(mainWork:)``) before any view
    /// draws; until then no read starts.
    @ObservationIgnored private var mainWork: MainWorkScheduler?

    /// - Parameters:
    ///   - clock: Times how long a read decode stays in use (``inUse``); tests pass their own.
    ///   - mainWork: Where reads' arrivals are posted (nil: none start until ``attach(mainWork:)``).
    init(clock: any Clock<Duration> = ContinuousClock(), mainWork: MainWorkScheduler? = nil) {
        elapsed = Self.elapsed(on: clock)
        self.mainWork = mainWork
    }

    /// Posts every later read's arrival on `mainWork`, the app's main-thread scheduler.
    func attach(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
    }

    private static func elapsed<C: Clock<Duration>>(on clock: C) -> () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// The image of asset icon `icon` (nil for an emoji or symbol, or until it is read).
    func image(_ icon: String, owner: DaemonService?) -> SidebarFavicon? {
        image(icon, from: Source(owner: owner))
    }

    /// The image of asset icon `icon`, read from `source` the first time and again after a release forgot it.
    func image(_ icon: String, from source: @autoclosure () -> Source?) -> SidebarFavicon? {
        guard let value = IconValue(wire: icon), Self.isAsset(value) else { return nil }
        let slot = slot(icon)
        if let image = slot.image {
            markUsed(slot)
            return image
        }
        guard !requested.contains(icon), let mainWork, let source = source() else { return nil }
        requested.insert(icon)
        let read = source.read
        // task-owner: one read per asset; it ends with the decode, and the cache outlives it weakly
        Task { @concurrent [weak self] in
            let arrival = await Self.arrival(of: icon, read: read)
            // `visible`: the sidebar and the strips redraw an icon no input of the person changed.
            mainWork.postFromAnyThread(.visible, owner: "IconAssetImages.arrived") { [weak self] in self?.arrived(arrival, for: icon) }
        }
        return nil
    }

    /// What one read of an asset came back with.
    private nonisolated enum Arrival: Sendable {
        case image(SidebarFavicon)
        /// The owner answered (no such asset) or the bytes do not decode: never read again.
        case refused
        /// The transport failed (no connection yet, a timeout): the next rebuild reads it again.
        case retry
    }

    /// Reads `icon` with `read` and decodes it, both off main.
    @concurrent private nonisolated static func arrival(of icon: String,
                                                        read: @Sendable (String) async throws -> (data: Data, mediaType: String)) async -> Arrival {
        let blob: (data: Data, mediaType: String)
        do {
            blob = try await read(icon)
        } catch {
            if case DaemonError.command? = error as? DaemonError { return .refused }
            return .retry
        }
        return await decoded(blob.data, mediaType: blob.mediaType).map(Arrival.image) ?? .refused
    }

    /// A read's arrival on main: stores the image, or forgets the request so a later read tries again.
    private func arrived(_ arrival: Arrival, for icon: String) {
        switch arrival {
        case .image(let image): store(image, for: icon)
        case .retry: requested.remove(icon)
        case .refused: break
        }
    }

    /// Keeps `image` as asset `icon`'s and tells its readers, dropping the least recently used decodes past
    /// ``keep`` (tests store a decode directly).
    func store(_ image: SidebarFavicon, for icon: String) {
        let slot = slot(icon)
        if let old = slot.image {
            imageBytes -= Self.bytes(of: old)
        } else {
            decodedCount += 1
        }
        imageBytes += Self.bytes(of: image)
        slot.tabImage = nil
        slot.image = image
        markUsed(slot)
        while decodedCount > Self.keep, let oldest = leastRecentlyUsed() { forget(oldest) }
    }

    private func slot(_ icon: String) -> Slot {
        if let slot = slots[icon] { return slot }
        let slot = Slot()
        slots[icon] = slot
        return slot
    }

    private func markUsed(_ slot: Slot) {
        slot.lastUse = nextUse
        nextUse += 1
        slot.usedAt = elapsed()
    }

    /// The decoded asset used least recently (one pass over at most ``keep`` + 1 decodes).
    private func leastRecentlyUsed() -> String? {
        var oldest: (icon: String, use: UInt64)?
        for (icon, slot) in slots where slot.image != nil && slot.lastUse < (oldest?.use ?? .max) {
            oldest = (icon, slot.lastUse)
        }
        return oldest?.icon
    }

    /// Forgets asset `icon`'s decode and that it was read, telling no reader (its slot goes, its image is
    /// not written): the views keep what they hold, and the next read reads it from its owner again.
    private func forget(_ icon: String) {
        guard let slot = slots[icon], let image = slot.image else { return }
        slots[icon] = nil
        imageBytes -= Self.bytes(of: image)
        decodedCount -= 1
        requested.remove(icon)
    }

    /// Forgets the least recently used decodes not in use (``inUse``) until at most `limit` stay or `slice`
    /// is spent.
    ///
    /// - Returns: False when `slice` ran out first; true when at most `limit` stay or only decodes in use are left.
    private func dropIdle(to limit: Int, within slice: MemoryReleaseSlice) -> Bool {
        let idleBefore = elapsed() - Self.inUse
        let idle = slots.filter { $0.value.image != nil && $0.value.usedAt < idleBefore }
            .sorted { $0.value.lastUse < $1.value.lastUse }
        for (icon, _) in idle where decodedCount > max(limit, 0) {
            if slice.isExpired { return false }
            forget(icon)
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
            guard let image = self.image(icon, owner: owner), let slot = self.slots[icon] else { return nil }
            if let cached = slot.tabImage, cached.cgImage === image.image { return cached }
            let tabImage = TabImage(image.image)
            slot.tabImage = tabImage
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
        guard let context = CGContext.bitmapOwningPixels(width: pixels, height: pixels,
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
/// forgets the least recently used decodes not in use, down to it, and tells no reader: an image a strip
/// or the sidebar draws stays in that view until its next mapping of the icon reads it again.
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
        return dropIdle(to: imageLimit, within: slice) ? .done : .more
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: imageBytes, entries: decodedCount)
    }
}
