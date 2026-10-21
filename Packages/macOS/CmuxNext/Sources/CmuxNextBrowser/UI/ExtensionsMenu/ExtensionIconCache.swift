import AppKit
import CmuxNextIcons

/// Extension icons for the Extensions bubble, decoded once per file and kept at the size the
/// bubble draws them. Chromium writes an extension's icons under a folder named for its version,
/// so a path names one image for as long as the extension stays installed; an update brings a
/// new path. Before, every open read and decoded every 128-pixel icon from disk on the main
/// thread.
@MainActor
final class ExtensionIconCache {
    private var images: [String: NSImage] = [:]
    private let side: CGFloat
    /// Files read (a test seam: a second open reads none).
    private(set) var loads = 0

    init(side: CGFloat = ExtensionsMenuStyle.standard.extensionIcon) {
        self.side = side
    }

    /// The bundled icon of `info` (its largest up to 128 pixels), else the toolbar icon `png`,
    /// else Chrome's puzzle piece named for VoiceOver.
    func image(for info: BrowserExtensionInfo, png: Data?) -> NSImage {
        if let path = info.iconPath, let cached = images[path] { return cached }
        let decoded: NSImage? = {
            if let path = info.iconPath {
                loads += 1
                if let image = NSImage(contentsOfFile: path) { return image }
            }
            return png.flatMap(NSImage.init(data:))
        }()
        let image = decoded.map(downsampled) ?? fallback(name: info.name)
        if let path = info.iconPath, decoded != nil { images[path] = image }
        return image
    }

    /// Renders `image` once at the drawn size and the screen's 2x, so a redraw (hover) scales
    /// nothing.
    private func downsampled(_ image: NSImage) -> NSImage {
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            image.size = NSSize(width: side, height: side)
            return image
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: side, height: side)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }

    private func fallback(name: String) -> NSImage {
        let image = NSImage.icon(.browserToolbarExtensions, size: side)
        image.accessibilityDescription = name
        return image
    }
}
