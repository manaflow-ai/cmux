import AppKit
import CmuxNextDesign
import CmuxNextPages
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Settings page's wallpaper thumbnails (R82 commit 4): `cmux-page://cmux.settings/backdrop/<id>`
/// answers a small PNG of that choice. Only ids in the bounded catalog, and the person's own
/// images in the backgrounds folder, are served, so the page cannot read arbitrary files through it.
@MainActor
final class SettingsBackdropThumbnails: PageDynamicResourceSource {
    static let prefix = "backdrop"
    private let allowed: Set<String>
    private let userImages: BackdropUserImages?
    private let museum: MuseumArtSession?
    private var cache: [String: Data] = [:]

    init(choices: [BackdropSelection], userImages: BackdropUserImages?, museum: MuseumArtSession? = nil) {
        allowed = Set(choices.map(\.id))
        self.userImages = userImages
        self.museum = museum
    }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        // Browse more art: a result's thumbnail, only for a key the latest searches returned.
        if request.prefix == MuseumArtSession.thumbnailPrefix, request.path.count == 1,
           let key = request.path[0].removingPercentEncoding, let data = await museum?.thumbnail(key: key) {
            // Commons thumbnails of PNG files are PNGs; everything else answers JPEG.
            return PageResource(data: data, mimeType: data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg")
        }
        guard request.prefix == Self.prefix, request.path.count == 1,
              let id = request.path[0].removingPercentEncoding, let selection = BackdropSelection(id: id),
              allowed.contains(id) || userImages?.contains(selection) == true else { return nil }
        if let data = cache[id] { return PageResource(data: data, mimeType: "image/png") }
        // Art reads its bundled thumbnail, so works that are not downloaded yet still show. A file
        // (a photo can be tens of megabytes) decodes off the main actor; the desktop picture,
        // which only the main actor can resolve, draws here.
        let data: Data?
        if let url = selection.thumbnailURL {
            data = await Task.detached { Self.thumbnail(at: url) }.value
        } else {
            data = selection.image().flatMap(Self.thumbnail)
        }
        guard let data else { return nil }
        cache[id] = data
        return PageResource(data: data, mimeType: "image/png")
    }

    /// A PNG at most 240 pixels wide of the image file at `url`, decoded by ImageIO at that size.
    nonisolated static func thumbnail(at url: URL) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A 240-point-wide PNG (the grid shows tiles about 112 points wide on a 2x display).
    static func thumbnail(_ image: NSImage) -> Data? {
        let width: CGFloat = 240
        let size = image.size.width > 0 ? NSSize(width: width, height: (width * image.size.height / image.size.width).rounded()) : NSSize(width: width, height: 135)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
