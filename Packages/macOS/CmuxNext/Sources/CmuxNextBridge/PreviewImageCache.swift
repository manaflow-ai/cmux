public import CoreGraphics

/// Downscaled tab preview images, least recently used first out, capped by
/// decoded byte size (architecture.md section 4: 32 MB total).
public final class PreviewImageCache {
    public let capacityBytes: Int
    public private(set) var totalBytes = 0
    private var images: [String: CGImage] = [:]
    /// Least recently used first.
    private var order: [String] = []

    public init(capacityBytes: Int = 32 << 20) {
        self.capacityBytes = capacityBytes
    }

    public var count: Int { images.count }

    public func image(for key: String) -> CGImage? {
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    public func insert(_ image: CGImage, for key: String) {
        let cost = Self.cost(image)
        guard cost <= capacityBytes else { return }
        remove(key)
        images[key] = image
        order.append(key)
        totalBytes += cost
        while totalBytes > capacityBytes, let oldest = order.first {
            remove(oldest)
        }
    }

    public func remove(_ key: String) {
        guard let image = images.removeValue(forKey: key) else { return }
        totalBytes -= Self.cost(image)
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
