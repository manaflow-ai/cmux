import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Hibernated pages' last frames, kept compressed (JPEG, or PNG when transparent) under their
/// own budget, least recently used first out, so every hibernated tab wakes to its picture
/// (PR 23083). They used to share the 32 MB decoded `previews` LRU with terminal previews at up
/// to a quarter of it each: four hibernated pages kept a picture and the others woke to an empty
/// pane.
///
/// A picture's image decodes from its bytes when drawn; the placeholder decodes it off the main
/// thread, and holds the decoded pixels only while a pane shows it (`HibernatedBrowserTab`).
@MainActor
final class HibernationSnapshots {
    /// A page picture at 2x is about 0.2 to 1.5 MB as JPEG, so this holds 40 to 300 of them.
    let capacityBytes: Int
    private(set) var totalBytes = 0
    private var pictures: [String: Picture] = [:]
    /// Least recently used first.
    private var order: [String] = []

    /// One page's picture: `data` is the JPEG or PNG (nil for a decoded picture kept in `previews`
    /// when `HibernationTunables.compressedSnapshots` is off), `image` decodes from it.
    nonisolated struct Picture: Sendable {
        let data: Data?
        let image: CGImage
    }

    init(capacityBytes: Int = 64 << 20) {
        self.capacityBytes = capacityBytes
    }

    var count: Int { pictures.count }

    func image(for key: String) -> CGImage? {
        guard let picture = pictures[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return picture.image
    }

    func insert(_ picture: Picture, for key: String) {
        guard let cost = picture.data?.count, cost <= capacityBytes else { return }
        remove(key)
        pictures[key] = picture
        order.append(key)
        totalBytes += cost
        while totalBytes > capacityBytes, let oldest = order.first { remove(oldest) }
    }

    func remove(_ key: String) {
        guard let picture = pictures.removeValue(forKey: key) else { return }
        totalBytes -= picture.data?.count ?? 0
        order.removeAll { $0 == key }
    }

    /// Pixels a picture keeps at most: a 2560 x 1600 pt pane at 2x (16.4 M) keeps its size.
    nonisolated static let maxPixels = 16 << 20

    /// `image` as a JPEG at most `maxPixels` large (same aspect and color space), encoded on a
    /// background task; a PNG when it has transparent pixels, which JPEG would turn black (a page
    /// with a transparent background); nil when ImageIO cannot encode it.
    nonisolated static func compress(_ image: CGImage, quality: Double = 0.8) async -> Picture? {
        await Task.detached(priority: .userInitiated) { compressed(image, quality: quality) }.value
    }

    nonisolated static func compressed(_ image: CGImage, quality: Double) -> Picture? {
        let pixels = Double(image.width * image.height)
        let scale = min(1, (Double(maxPixels) / max(pixels, 1)).squareRoot())
        let source = scale < 1
            ? TabPreviewFitting.fitted(image, CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
            : image
        let data = NSMutableData()
        let type = isOpaque(source) ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let reader = CGImageSourceCreateWithData(data, nil),
              let decoded = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return Picture(data: data as Data, image: decoded)
    }

    /// True when `image` has no alpha, or no transparent pixel in a 32 x 32 sample of it (a
    /// transparent background spans most of a page; an engine's opaque picture often has alpha).
    nonisolated static func isOpaque(_ image: CGImage) -> Bool {
        if [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return true }
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: side * side * 4) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: side * side * 4, by: 4).allSatisfy { pixels[$0] == 255 }
    }
}
