import CmuxNextBridge
package import CoreGraphics
package import Foundation

/// Hibernated pages' last frames, kept compressed (JPEG, or PNG when transparent) under their
/// own budget, least recently used first out, so every hibernated tab wakes to its picture
/// (PR 23083). They used to share the 32 MB decoded `previews` LRU with terminal previews at up
/// to a quarter of it each: four hibernated pages kept a picture and the others woke to an empty
/// pane.
///
/// A picture's image decodes from its bytes when drawn; the placeholder decodes it off the main
/// thread, and holds the decoded pixels only while a pane shows it (`HibernatedBrowserTab`).
@MainActor
package final class HibernationSnapshots {
    /// A page picture at 2x is about 0.2 to 1.5 MB as JPEG, so this holds 40 to 300 of them.
    package let capacityBytes: Int
    package private(set) var totalBytes = 0
    private var pictures: [String: Picture] = [:]
    /// Least recently used first.
    private var order: [String] = []

    /// One page's picture: `data` is the JPEG or PNG (nil for a decoded picture kept in `previews`
    /// when `HibernationTunables.compressedSnapshots` is off), `image` decodes from it.
    package nonisolated struct Picture: Sendable {
        package let data: Data?
        package let image: CGImage

        package init(data: Data?, image: CGImage) {
            self.data = data
            self.image = image
        }
    }

    package init(capacityBytes: Int = 64 << 20) {
        self.capacityBytes = capacityBytes
    }

    package var count: Int { pictures.count }

    package func image(for key: String) -> CGImage? {
        guard let picture = pictures[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return picture.image
    }

    package func insert(_ picture: Picture, for key: String) {
        guard let cost = picture.data?.count, cost <= capacityBytes else { return }
        remove(key)
        pictures[key] = picture
        order.append(key)
        totalBytes += cost
        while totalBytes > capacityBytes, let oldest = order.first { remove(oldest) }
    }

    package func remove(_ key: String) {
        guard let picture = pictures.removeValue(forKey: key) else { return }
        totalBytes -= picture.data?.count ?? 0
        order.removeAll { $0 == key }
    }

    /// `image` as a JPEG at most `PreviewImageCache.maxCompressedPixels` large (same aspect and color space), encoded on a
    /// background task; a PNG when it has transparent pixels, which JPEG would turn black (a page
    /// with a transparent background); nil when ImageIO cannot encode it.
    package nonisolated static func compress(_ image: CGImage, quality: Double = 0.8) async -> Picture? {
        await Task.detached(priority: .userInitiated) { compressed(image, quality: quality) }.value
    }

    package nonisolated static func compressed(_ image: CGImage, quality: Double) -> Picture? {
        PreviewImageCache.compressed(image, quality: quality).map { Picture(data: $0.data, image: $0.image) }
    }
}
