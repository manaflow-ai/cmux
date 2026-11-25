public import CoreGraphics
public import Foundation

/// Downscaled tab preview images, least recently used first out, capped by
/// byte size (architecture.md section 4: 32 MB total): an image's decoded size, or
/// the compressed size its owner gives for an image that decodes from data when drawn.
public final class PreviewImageCache {
    public let capacityBytes: Int
    public private(set) var totalBytes = 0
    private var images: [String: CGImage] = [:]
    /// What each image counts against `capacityBytes`.
    private var costs: [String: Int] = [:]
    /// Least recently used first.
    private var order: [String] = []
    /// Encodes a picture this cache keeps compressed, wherever it is called (a test injects one it can hold).
    public var encode: @Sendable (CGImage) async -> (data: Data, image: CGImage)? = { PreviewImageCache.compressed($0, quality: 0.8) }

    public init(capacityBytes: Int = 32 << 20) {
        self.capacityBytes = capacityBytes
    }

    public var count: Int { images.count }

    /// Replaces `key`'s image with `replacement` at `cost` only while `key` still holds `current` (the same object):
    /// a later picture of the tab is never overwritten by an older one finished late. Keeps its recency. A replacement
    /// that saves no bytes (a compressed copy larger than the decoded picture) is refused, so a replace only ever lowers
    /// `totalBytes` and the store stays within `capacityBytes` with no eviction.
    @discardableResult
    public func replace(_ current: CGImage, for key: String, with replacement: CGImage, cost: Int) -> Bool {
        guard images[key] === current, let old = costs[key], cost < old else { return false }
        images[key] = replacement
        costs[key] = cost
        totalBytes += cost - old
        return true
    }

    public func image(for key: String) -> CGImage? {
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    public func insert(_ image: CGImage, for key: String) {
        insert(image, for: key, cost: Self.cost(image))
    }

    /// Keeps `image` at `cost` bytes: an image that decodes from compressed data when drawn (ImageIO, no cache)
    /// holds only that data, so it counts its compressed size.
    public func insert(_ image: CGImage, for key: String, cost: Int) {
        guard cost <= capacityBytes else { return }
        remove(key)
        images[key] = image
        costs[key] = cost
        order.append(key)
        totalBytes += cost
        while totalBytes > capacityBytes, let oldest = order.first {
            remove(oldest)
        }
    }

    public func remove(_ key: String) {
        guard images.removeValue(forKey: key) != nil else { return }
        totalBytes -= costs.removeValue(forKey: key) ?? 0
        order.removeAll { $0 == key }
    }

    static func cost(_ image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, image.width * image.height * 4)
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
