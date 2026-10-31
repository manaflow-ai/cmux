import CmuxNextIcons
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The React App Store's images (plans/cmux-next/apps-web-DESIGN.md). `glyph/<name>` answers a
/// PNG alpha mask of cmux's own pack drawing for a symbol name (an app manifest's `symbol`) or an
/// cmux icon name; a name the pack does not draw is a 404, never Apple's SF
/// Symbol (coordinator Q5), and the page shows its fallback.
@MainActor
public final class AppsGlyphResource: PageDynamicResourceSource {
    /// The App Store page's icon resource namespace.
    public static let prefix = AppsPageNativeOps.glyphPrefix
    /// Points of the mask; the page scales it down, so one size serves every tile.
    nonisolated static let side: CGFloat = 32
    nonisolated static let scale: CGFloat = 2
    private var cache: [String: Data] = [:]

    /// Creates a per-page glyph cache.
    public init() {}

    public func resource(for request: PageResourceRequest) async -> PageResource? {
        guard request.path.count == 1, let name = request.path[0].removingPercentEncoding else { return nil }
        guard request.prefix == Self.prefix else { return nil }
        if let data = cache[name] { return PageResource(data: data, mimeType: "image/png") }
        guard let data = Self.png(name) else { return nil }
        cache[name] = data
        return PageResource(data: data, mimeType: "image/png")
    }

    /// The pack drawing of `name` (a symbol the catalog maps, else an icon name) as a PNG; nil
    /// when the pack has no drawing for it.
    nonisolated static func png(_ name: String) -> Data? {
        let icon = IconCatalog.bundled.name(forSymbol: name) ?? IconName(name)
        guard let image = CGImage.icon(icon, size: side, scale: scale, tint: CGColor(gray: 0, alpha: 1)) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
