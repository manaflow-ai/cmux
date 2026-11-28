import AppKit
import CmuxAgentBrands

/// Agent brand marks drawn in the tab's tint (the mono style), cached per brand, tint, and scale.
final class TabAgentMarkCache {
    static let shared = TabAgentMarkCache()
    private var cache: [String: CGImage] = [:]

    /// The mark fills about the symbol's optical size inside the icon square.
    private static let fill: CGFloat = 0.82

    /// `terminal` draws the mark smaller on a soft rounded square of `tint` (a terminal agent's tab).
    func image(brand: String, tint: NSColor, size: CGFloat, scale: CGFloat, terminal: Bool = false) -> CGImage? {
        guard let spec = AgentBrandCatalog.spec(for: AgentBrandID(rawValue: brand))?.variant(forPointSize: Double(size)) else { return nil }
        let resolved = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(brand)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)|\(resolved.alphaComponent)|\(size)|\(scale)|\(terminal)"
        if let cached = cache[key] { return cached }
        let pixels = Int((size * scale).rounded())
        guard pixels > 0, let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if terminal {
            let box = CGRect(x: 0, y: 0, width: pixels, height: pixels)
            context.addPath(CGPath(roundedRect: box, cornerWidth: box.width * AgentBrandCatalog.terminalTileCornerShare,
                                   cornerHeight: box.height * AgentBrandCatalog.terminalTileCornerShare, transform: nil))
            context.setFillColor(resolved.withAlphaComponent(resolved.alphaComponent * AgentBrandCatalog.terminalTileAlpha).cgColor)
            context.fillPath()
        }
        let side = CGFloat(pixels) * (terminal ? AgentBrandCatalog.terminalTileMarkShare : Self.fill)
        let inset = (CGFloat(pixels) - side) / 2
        AgentBrandRenderer.draw(
            spec, in: context, rect: CGRect(x: inset, y: inset, width: side, height: side),
            style: .mono, dark: false, monoColor: resolved.cgColor, flipped: false
        )
        let image = context.makeImage()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
