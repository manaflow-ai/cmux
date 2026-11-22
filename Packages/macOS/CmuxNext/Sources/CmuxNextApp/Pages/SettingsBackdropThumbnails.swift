import AppKit
import CmuxNextDesign
import CmuxNextPages
import Foundation

/// The Settings page's wallpaper thumbnails (R82 commit 4): `cmux-page://cmux.settings/backdrop/<id>`
/// answers a small PNG of that choice. Only ids in the bounded catalog are served, so the page
/// cannot read arbitrary files through it.
@MainActor
final class SettingsBackdropThumbnails: PageDynamicResourceSource {
    static let prefix = "backdrop"
    private let allowed: Set<String>
    private var cache: [String: Data] = [:]

    init(choices: [BackdropSelection]) {
        allowed = Set(choices.map(\.id))
    }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard request.prefix == Self.prefix, request.path.count == 1,
              let id = request.path[0].removingPercentEncoding, allowed.contains(id),
              let selection = BackdropSelection(id: id) else { return nil }
        if let data = cache[id] { return PageResource(data: data, mimeType: "image/png") }
        guard let image = selection.image(), let data = Self.thumbnail(image) else { return nil }
        cache[id] = data
        return PageResource(data: data, mimeType: "image/png")
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
