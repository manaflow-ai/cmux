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
/// That decode takes 10 to 30 ms for a full page, so a large picture also keeps a small decoded
/// `preview` (at most `previewPixelSize` on its long side, a few hundred KB) that the placeholder
/// shows in the turn it enters a window: a woken tab shows a picture in its first frame.
@MainActor
final class HibernationSnapshots {
    /// A page picture at 2x is about 0.2 to 1.5 MB as JPEG, so this holds 40 to 300 of them.
    let capacityBytes: Int
    private(set) var totalBytes = 0
    private var pictures: [String: Picture] = [:]
    /// Least recently used first.
    private var order: [String] = []

    /// One page's picture: `data` is the JPEG or PNG (nil for a decoded picture kept in `previews`
    /// when `HibernationTunables.compressedSnapshots` is off), `image` decodes from it, `preview`
    /// is a small decoded copy shown until `image` is decoded (nil for a small picture).
    nonisolated struct Picture: Sendable {
        let data: Data?
        let image: CGImage
        var preview: CGImage?

        /// Bytes it holds in the store: the encoded picture and the decoded preview.
        var cost: Int { (data?.count ?? 0) + (preview.map { $0.bytesPerRow * $0.height } ?? 0) }
    }

    /// The long side of a picture's decoded preview: 384 x 240 at 4 bytes is 360 KB.
    nonisolated static let previewPixelSize = 384

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

    /// `key`'s decoded preview, shown at once while its picture decodes.
    func preview(for key: String) -> CGImage? { pictures[key]?.preview }

    func insert(_ picture: Picture, for key: String) {
        guard picture.data != nil, picture.cost <= capacityBytes else { return }
        remove(key)
        pictures[key] = picture
        order.append(key)
        totalBytes += picture.cost
        while totalBytes > capacityBytes, let oldest = order.first { remove(oldest) }
    }

    func remove(_ key: String) {
        guard let picture = pictures.removeValue(forKey: key) else { return }
        totalBytes -= picture.cost
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
        // Drawn into a bitmap from the source pixels: decoded, so the first frame shows it with no decode.
        let side = Double(previewPixelSize)
        let preview = max(source.width, source.height) > previewPixelSize * 2
            ? TabPreviewFitting.fitted(source, CGSize(width: side, height: side)) : nil
        return Picture(data: data as Data, image: decoded, preview: preview)
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
