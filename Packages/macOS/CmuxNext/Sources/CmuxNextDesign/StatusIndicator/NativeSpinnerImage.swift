import AppKit

/// The AppKit spinning indicator's spokes, rendered once per pixel size by
/// NSProgressIndicator itself and used as an alpha mask, so the native
/// style is pixel-identical to the control yet costs one layer and runs its
/// stepped rotation in the render server (no NSView, no timer, no idle
/// wakeups). The control draws black spokes whose alpha fades clockwise
/// from the top spoke; tinting the mask keeps that fade in any color.
@MainActor
enum NativeSpinnerImage {
    private static var cache: [Int: CGImage] = [:]
    /// Cache key: pixel side and backing scale (AppKit draws different
    /// spokes for 16 pt at 2x than for 32 pt at 1x).
    private static func key(_ pixels: Int, _ scale: CGFloat) -> Int { pixels * 8 + Int(scale.rounded()) }
    /// Sizes AppKit drew nothing for, so a failure is not retried per layout.
    private static var failed: Set<Int> = []

    /// Spokes for a `side`-point square at `scale` (nil if AppKit drew nothing).
    static func image(side: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0 else { return nil }
        let key = key(pixels, scale)
        if let cached = cache[key] { return cached }
        if failed.contains(key) { return nil }
        let points = CGFloat(pixels) / scale
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: points, height: points))
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = true
        indicator.appearance = NSAppearance(named: .aqua)
        // A windowless view caches at 1x; draw into a rep with the pixel
        // size explicitly so the mask is sharp on Retina.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: points, height: points)
        indicator.cacheDisplay(in: indicator.bounds, to: rep)
        guard let image = rep.cgImage.flatMap(normalized) else {
            failed.insert(key)
            return nil
        }
        if cache.count > 16 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// The control's spokes peak near 55% alpha (they are drawn over its
    /// own gray); scale the alpha so the leading spoke is fully opaque and
    /// the tint color reads at small sizes, keeping the fade ratios.
    private static func normalized(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        var peak: UInt8 = 0
        for i in 0..<(width * height) { peak = max(peak, bytes[i]) }
        guard peak > 0 else { return nil }
        let factor = 255 / Double(peak)
        for i in 0..<(width * height) { bytes[i] = UInt8(min(255, (Double(bytes[i]) * factor).rounded())) }
        return context.makeImage()
    }
}
