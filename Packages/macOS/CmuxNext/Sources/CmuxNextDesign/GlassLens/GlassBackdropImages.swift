public import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The wallpaper stills pages lens (`image` of the `cmuxTheme.backdrop` payload): each art image
/// as a `data:image/jpeg` URL no wider than ``maxPixelSize``, encoded once off the main actor and
/// shared by every page that shows the same art (the decoded art is one `NSImage` per art,
/// `BackdropImageStore`). A few recent ones are kept, keyed by image identity.
@MainActor
public final class GlassBackdropImages {
    /// The app's stills.
    public static let shared = GlassBackdropImages()

    /// The longest side of a still, in pixels.
    public let maxPixelSize: Int
    private let capacity: Int
    private var entries: [Entry] = []
    private var serial = 0

    private final class Entry {
        let image: NSImage
        let key: String
        var dataURL: String?
        var waiters: [@MainActor () -> Void] = []
        var encode: Task<Void, Never>?

        init(image: NSImage, key: String) {
            self.image = image
            self.key = key
        }
    }

    /// A bitmap handed to the encoding task.
    // crash-allow: an immutable CGImage is only read by the detached encoder.
    private struct Bitmap: @unchecked Sendable {
        let image: CGImage
    }

    /// - Parameters:
    ///   - maxPixelSize: The longest side of a still.
    ///   - capacity: How many stills stay encoded.
    public init(maxPixelSize: Int = 1024, capacity: Int = 4) {
        self.maxPixelSize = max(maxPixelSize, 16)
        self.capacity = max(capacity, 1)
    }

    /// The key and, once encoded, the data URL of `image` (empty when it could not be encoded).
    /// While it encodes the URL is nil and `ready` runs on the main actor when it is done; nil
    /// when the image has no bitmap.
    public func still(_ image: NSImage, ready: @escaping @MainActor () -> Void) -> (key: String, dataURL: String?)? {
        if let index = entries.firstIndex(where: { $0.image === image }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            if entry.dataURL == nil { entry.waiters.append(ready) }
            return (entry.key, entry.dataURL)
        }
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        serial += 1
        let entry = Entry(image: image, key: "still-\(serial)")
        entry.waiters = [ready]
        entries.append(entry)
        if entries.count > capacity {
            let evicted = entries.prefix(entries.count - capacity)
            evicted.forEach { $0.encode?.cancel() }
            entries.removeFirst(evicted.count)
        }
        let source = Bitmap(image: bitmap), size = maxPixelSize
        entry.encode = Task { [weak entry] in
            let url = await Task.detached(priority: .utility) { Self.jpegDataURL(source.image, maxPixelSize: size) }.value
            guard let entry, !Task.isCancelled else { return }
            entry.dataURL = url ?? ""
            let waiters = entry.waiters
            entry.waiters = []
            entry.encode = nil
            waiters.forEach { $0() }
        }
        return (entry.key, nil)
    }

    /// `image` scaled down to at most `maxPixelSize` on its longest side and encoded as a JPEG
    /// data URL; nil when it cannot be drawn or encoded. Runs off the main actor.
    nonisolated static func jpegDataURL(_ image: CGImage, maxPixelSize: Int) -> String? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / Double(longest))
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}
