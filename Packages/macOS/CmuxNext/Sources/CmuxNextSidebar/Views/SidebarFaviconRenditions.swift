import AppKit
import Observation

/// The one path every sidebar surface draws a page favicon through (a workspace row's icon, a band item, the hover
/// card's tab rows; Lawrence msg 19869, "also see if we can make these favicons look better"): the favicon as
/// ``SidebarFaviconStyle`` treats it on the ground under it, at the drawn size.
///
/// A favicon's ink (`SidebarFaviconInk`) is measured once per image, and each drawn bitmap (a high-quality downsample of
/// the source, inverted or on a plate when the style says) is made once per image, treatment and pixel size, so a
/// configure, a status tick or an appearance change never measures or resamples again. Each view that draws favicons
/// owns one: keyed by the image's identity (`TabFaviconStore` keeps one `CGImage` per loaded icon), and the entry holds
/// the image, so an identifier is never reused for another image while its entry lives.
@MainActor final class SidebarFaviconRenditions {
    /// Images kept before the cache starts over: a row shows one favicon at a time, a recycled row a new one.
    let capacity: Int
    /// Runs once after `sidebar.faviconStyle` changes, when a ``drawing(_:side:scale:ground:)`` read it since the last
    /// change: the owning view draws its favicon again.
    var onStyleChange: (() -> Void)?

    private struct Entry {
        let image: CGImage
        let ink: SidebarFaviconInk?
        var drawn: [DrawnKey: NSImage] = [:]
    }

    private struct DrawnKey: Hashable {
        var treatment: SidebarFaviconTreatment
        var pixels: Int
        var side: CGFloat
        var darkGround: Bool
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// An observation of `sidebar.faviconStyle` is registered and has not fired yet.
    private var watchesStyle = false

    /// - Parameter capacity: images kept before the cache starts over.
    init(capacity: Int = 4) {
        self.capacity = capacity
    }

    /// The measured ink of `image`, measured on first ask.
    func ink(of image: CGImage) -> SidebarFaviconInk? { entry(image).ink }

    /// `favicon` as the current favicon style draws it at `side` points on a ground of relative luminance `ground`
    /// (``groundLuminance(_:)``), for a screen of `scale` pixels per point. A template drawing takes its ink from the
    /// image view (`contentTintColor`): the label colour of the surface.
    func drawing(_ favicon: SidebarFavicon, side: CGFloat, scale: CGFloat, ground: Double) -> SidebarFaviconDrawing {
        watchStyle()
        let style = SidebarFaviconStyle.tunable.value
        let source = favicon.image
        let treatment = style == .current ? SidebarFaviconTreatment.original : style.treatment(for: ink(of: source), ground: ground)
        // At least 2x, so a 1x screen still downsamples from a sharper bitmap.
        let pixels = max(1, Int((side * max(2, scale)).rounded()))
        let key = DrawnKey(treatment: treatment, pixels: pixels, side: side,
                           darkGround: treatment.hasPlate && ground < SidebarFaviconStyle.darkGround)
        if let image = entry(source).drawn[key] { return SidebarFaviconDrawing(image: image, treatment: treatment, pixels: pixels) }
        let size = NSSize(width: side, height: side)
        let image: NSImage = switch treatment {
        case .original: NSImage(cgImage: source, size: size)
        case .smooth, .template: NSImage(cgImage: Self.resample(source, pixels: pixels) ?? source, size: size)
        case .inverted: NSImage(cgImage: Self.resample(source, pixels: pixels).flatMap(Self.invert) ?? source, size: size)
        case let .plate(circle): NSImage(cgImage: Self.plated(source, pixels: pixels, circle: circle, dark: key.darkGround) ?? source, size: size)
        }
        image.isTemplate = treatment == .template
        entries[ObjectIdentifier(source)]?.drawn[key] = image
        return SidebarFaviconDrawing(image: image, treatment: treatment, pixels: pixels)
    }

    /// The WCAG relative luminance of a ground `color` (its alpha ignored: the ground is taken as opaque).
    static func groundLuminance(_ color: NSColor) -> Double {
        let ground = color.usingColorSpace(.sRGB) ?? .black
        return SidebarFaviconInk.relativeLuminance(Double(ground.redComponent), Double(ground.greenComponent), Double(ground.blueComponent))
    }

    /// Share of a plate's side the favicon keeps clear on each edge.
    static let plateInset: CGFloat = 0.15

    private func entry(_ image: CGImage) -> Entry {
        let key = ObjectIdentifier(image)
        if let entry = entries[key], entry.image === image { return entry }
        if entries.count >= capacity { entries.removeAll() }
        let entry = Entry(image: image, ink: SidebarFaviconInk.measure(image))
        entries[key] = entry
        return entry
    }

    private func watchStyle() {
        guard !watchesStyle else { return }
        watchesStyle = true
        withObservationTracking {
            _ = SidebarFaviconStyle.tunable.value
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchesStyle = false
                self.onStyleChange?()
            }
        }
    }

    private static func context(pixels: Int) -> CGContext? {
        CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws `image` fit (aspect kept, centered) in a `pixels` square less `inset` pixels on each edge, high-quality.
    private static func draw(_ image: CGImage, in context: CGContext, pixels: Int, inset: CGFloat) {
        context.interpolationQuality = .high
        let box = CGFloat(pixels) - 2 * inset
        let fit = min(box / CGFloat(image.width), box / CGFloat(image.height))
        let width = CGFloat(image.width) * fit, height = CGFloat(image.height) * fit
        context.draw(image, in: CGRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2, width: width, height: height))
    }

    private static func resample(_ image: CGImage, pixels: Int) -> CGImage? {
        guard pixels > 0, image.width > 0, image.height > 0, let context = context(pixels: pixels) else { return nil }
        draw(image, in: context, pixels: pixels, inset: 0)
        return context.makeImage()
    }

    /// `image` inset on a plate filling the square: a light plate on a dark ground, a faint dark one on a light ground.
    private static func plated(_ image: CGImage, pixels: Int, circle: Bool, dark: Bool) -> CGImage? {
        guard pixels > 0, image.width > 0, image.height > 0, let context = context(pixels: pixels) else { return nil }
        let square = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.setFillColor(dark ? CGColor(gray: 1, alpha: 0.88) : CGColor(gray: 0, alpha: 0.07))
        let radius = circle ? CGFloat(pixels) / 2 : (CGFloat(pixels) * 0.25).rounded()
        context.addPath(CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        draw(image, in: context, pixels: pixels, inset: (CGFloat(pixels) * plateInset).rounded())
        return context.makeImage()
    }

    private static func invert(_ image: CGImage) -> CGImage? {
        guard image.width == image.height, let context = context(pixels: image.width) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = y * context.bytesPerRow + x * 4
                let alpha = pixels[i + 3]
                // Premultiplied: the inverse of c (of alpha) is alpha - c.
                for c in 0..<3 { pixels[i + c] = alpha &- min(pixels[i + c], alpha) }
            }
        }
        return context.makeImage()
    }
}
