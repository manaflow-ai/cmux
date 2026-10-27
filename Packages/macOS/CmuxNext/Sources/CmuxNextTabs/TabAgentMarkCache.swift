import AppKit
import CmuxAgentBrands

/// Agent brand marks drawn in the tab's tint (the mono style), cached per brand, tint, and scale: a memory
/// consumer (`tab-agent-marks`, ``TabImageMemo``) the app registers through ``TabIconMemoryConsumers``.
final class TabAgentMarkCache {
    static let shared = TabAgentMarkCache()
    let images: TabImageMemo<CGImage>

    /// The mark fills about the symbol's optical size inside the icon square.
    private static let fill: CGFloat = 0.82

    /// - Parameter clock: Times how long a drawn mark stays in use; tests pass their own.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        images = TabImageMemo(name: "tab-agent-marks", capacity: 256, bytes: TabImageMemo<CGImage>.pixelBytes(_:), clock: clock)
    }

    func image(brand: String, tint: NSColor, size: CGFloat, scale: CGFloat) -> CGImage? {
        guard let spec = AgentBrandCatalog.spec(for: AgentBrandID(rawValue: brand))?.variant(forPointSize: Double(size)) else { return nil }
        let resolved = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(brand)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)|\(resolved.alphaComponent)|\(size)|\(scale)"
        return images.value(for: key) { Self.draw(spec, tint: resolved, size: size, scale: scale) }
    }

    /// `spec` in `resolved`, the mono style, centered in a square of `size` points at `scale`.
    static func draw(_ spec: AgentBrandSpec, tint resolved: NSColor, size: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((size * scale).rounded())
        guard pixels > 0, let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let side = CGFloat(pixels) * Self.fill
        let inset = (CGFloat(pixels) - side) / 2
        AgentBrandRenderer.draw(
            spec, in: context, rect: CGRect(x: inset, y: inset, width: side, height: side),
            style: .mono, dark: false, monoColor: resolved.cgColor, flipped: false
        )
        return context.makeImage()
    }
}
