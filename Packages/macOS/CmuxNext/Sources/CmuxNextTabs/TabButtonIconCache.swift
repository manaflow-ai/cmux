import AppKit

/// Rasterized trailing-button icons. Symbols go through `TabSymbolCache`;
/// image files are loaded once per URL and drawn as-is, or tinted when the
/// image is a template.
final class TabButtonIconCache {
    static let shared = TabButtonIconCache()
    private var files: [URL: NSImage?] = [:]
    private var rendered: [String: CGImage] = [:]

    func image(for icon: TabStripButton.Icon, tint: NSColor, pointSize: CGFloat, size: CGFloat, scale: CGFloat) -> CGImage? {
        switch icon {
        case .symbol(let name):
            return TabSymbolCache.shared.image(named: name, tint: tint, pointSize: pointSize, size: size, scale: scale)
                ?? TabSymbolCache.shared.image(named: "questionmark.square.dashed", tint: tint, pointSize: pointSize, size: size, scale: scale)
        case .file(let url):
            guard let source = file(url) else {
                return TabSymbolCache.shared.image(named: "questionmark.square.dashed", tint: tint, pointSize: pointSize, size: size, scale: scale)
            }
            let resolved = tint.usingColorSpace(.sRGB) ?? tint
            let tintKey = source.isTemplate ? "\(resolved.redComponent)|\(resolved.alphaComponent)" : "-"
            let key = "\(url.path)|\(tintKey)|\(size)|\(scale)"
            if let cached = rendered[key] { return cached }
            let image = draw(source, template: source.isTemplate ? resolved : nil, size: size, scale: scale)
            if rendered.count > 64 { rendered.removeAll() }
            rendered[key] = image
            return image
        }
    }

    private func file(_ url: URL) -> NSImage? {
        if let cached = files[url] { return cached }
        let image = NSImage(contentsOf: url)
        files[url] = image
        return image
    }

    private func draw(_ source: NSImage, template tint: NSColor?, size: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((size * scale).rounded())
        guard pixels > 0, let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let natural = source.size
        let ratio = natural.width > 0 && natural.height > 0 ? min(size / natural.width, size / natural.height) : 1
        let drawSize = CGSize(width: natural.width * ratio, height: natural.height * ratio)
        let rect = CGRect(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2, width: drawSize.width, height: drawSize.height)
        source.draw(in: rect)
        if let tint {
            tint.setFill()
            rect.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
