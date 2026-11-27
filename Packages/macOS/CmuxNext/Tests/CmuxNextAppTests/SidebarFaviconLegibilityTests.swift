import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence msg 19869 ("also see if we can make these favicons look better"): the GitHub favicon, a dark mark on
/// transparent, drew as a muddy circle barely visible on the dark sidebar. A sidebar icon view draws a GitHub-like
/// monochrome mark on the themed sidebar ground (Soft Blue and Soft Blue Light) and the drawn pixels are read back.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFaviconLegibilityTests {
    /// A 64 px GitHub-like mark: a filled circle in one grey ink with a shape knocked out of it, on transparent.
    static func monoMark(white: Bool, pixels: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let side = CGFloat(pixels)
        ctx.setFillColor(white ? CGColor(gray: 1, alpha: 1) : CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: side * 0.03, y: side * 0.03, width: side * 0.94, height: side * 0.94))
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: side * 0.3, y: side * 0.3, width: side * 0.4, height: side * 0.36))
        ctx.fill(CGRect(x: side * 0.42, y: side * 0.08, width: side * 0.16, height: side * 0.26))
        return ctx.makeImage()!
    }

    /// A 64 px colourful mark (a Google-like circle in four colours) on transparent.
    static func colourful(pixels: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let half = CGFloat(pixels) / 2
        let colours = [CGColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1), CGColor(red: 0.2, green: 0.66, blue: 0.33, alpha: 1),
                       CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1), CGColor(red: 0.98, green: 0.74, blue: 0.02, alpha: 1)]
        for (index, colour) in colours.enumerated() {
            ctx.setFillColor(colour)
            ctx.fill(CGRect(x: CGFloat(index % 2) * half, y: CGFloat(index / 2) * half, width: half, height: half))
        }
        ctx.setBlendMode(.destinationIn)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        return ctx.makeImage()!
    }

    /// What a drawn favicon cell gives back: the screenshot, its pixels per point, the image view's frame (root
    /// points, bottom-left origin), the image it draws, and the ground colour.
    struct Drawn {
        var shot: CGImage
        var scale: CGFloat
        var iconFrame: CGRect
        var image: NSImage?
        var ground: (Double, Double, Double)
    }

    /// Draws `image` as a workspace row's favicon (its ink at the column's leading edge) on the themed sidebar ground.
    static func draw(_ image: CGImage?, dark: Bool) throws -> Drawn {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 40))
        window.contentView = root
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        root.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
        let view = SidebarIconView(frame: NSRect(x: 12, y: 10, width: SidebarStyle.iconColumnBox, height: 20))
        view.leadsWithInk = true
        root.addSubview(view)
        view.configure(icon: image.map { .favicon(SidebarFavicon($0)) })
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let shot = try AAPinnedNoCloseGalleryTests.crop(root, root.bounds)
        let imageView = try #require(view.subviews.compactMap { $0 as? NSImageView }.first)
        let scale = CGFloat(shot.width) / root.bounds.width
        let ground = try pixel(shot, x: 1, y: 1)
        return Drawn(shot: shot, scale: scale, iconFrame: root.convert(imageView.bounds, from: imageView), image: imageView.image,
                     ground: (ground.r, ground.g, ground.b))
    }

    /// The sRGB colour of pixel (x, y) of `image`, rows from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        let pixels = try rgba(image)
        let i = (y * image.width + x) * 4
        return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
    }

    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try #require(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// The pixels of `drawn`'s icon frame, as (r, g, b) tuples.
    static func iconPixels(_ drawn: Drawn) throws -> [(Double, Double, Double)] {
        let pixels = try rgba(drawn.shot)
        let f = drawn.iconFrame
        let height = CGFloat(drawn.shot.height) / drawn.scale
        let x0 = Int((f.minX * drawn.scale).rounded()), x1 = Int((f.maxX * drawn.scale).rounded())
        let y0 = Int(((height - f.maxY) * drawn.scale).rounded()), y1 = Int(((height - f.minY) * drawn.scale).rounded())
        var out: [(Double, Double, Double)] = []
        for y in max(0, y0)..<min(drawn.shot.height, y1) {
            for x in max(0, x0)..<min(drawn.shot.width, x1) {
                let i = (y * drawn.shot.width + x) * 4
                out.append((Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255))
            }
        }
        return out
    }

    /// A monochrome favicon's ink keeps WCAG's 3:1 for marks against the sidebar it draws on: a dark mark on the dark
    /// sidebar (the GitHub case) and a white one on the light sidebar, and in the other two pairings, where it already reads.
    @Test(arguments: [(false, true), (true, false), (false, false), (true, true)])
    func aMonochromeFaviconReadsOnTheSidebar(white: Bool, dark: Bool) throws {
        let drawn = try Self.draw(Self.monoMark(white: white), dark: dark)
        let ground = Self.luminance(drawn.ground)
        let contrasts = try Self.iconPixels(drawn).map { Self.contrast(Self.luminance($0), ground) }.sorted()
        try #require(!contrasts.isEmpty, "the favicon drew nothing")
        // The mark covers about 70% of its square: the 80th percentile pixel is ink, not ground.
        let ink = contrasts[contrasts.count * 8 / 10]
        #expect(ink >= 3, "a \(white ? "white" : "dark") mono favicon on the \(dark ? "dark" : "light") sidebar has \(String(format: "%.2f", ink)):1 against it")
    }

    /// A colourful favicon keeps its colours: its red quarter still draws red on the dark sidebar.
    @Test func aColourfulFaviconKeepsItsColours() throws {
        let drawn = try Self.draw(Self.colourful(), dark: true)
        let reds = try Self.iconPixels(drawn).filter { $0.0 > 0.7 && $0.1 < 0.4 && $0.2 < 0.4 }
        #expect(reds.count > 20, "the red quarter lost its colour (\(reds.count) red pixels)")
    }

    /// The favicon fills the icon column crisply: its frame sits on the pixel grid, and the image it draws holds at least
    /// 2x the drawn points in pixels when the source has them.
    @Test(arguments: [true, false])
    func aFaviconIsPixelAlignedAndSharp(dark: Bool) throws {
        let source = Self.monoMark(white: false)
        let drawn = try Self.draw(source, dark: dark)
        let f = drawn.iconFrame
        for (name, value) in [("x", f.minX), ("y", f.minY), ("width", f.width), ("height", f.height)] {
            let pixels = value * drawn.scale
            #expect(abs(pixels - pixels.rounded()) < 0.01, "the favicon's \(name) \(value) is off the \(drawn.scale)x pixel grid")
        }
        // The bitmap behind the image (an NSImage rep made from a CGImage reports its size in points, not pixels).
        var proposed = CGRect(x: 0, y: 0, width: f.width * 2, height: f.height * 2)
        let bitmap = try #require(drawn.image?.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        let wanted = min(CGFloat(source.width), (f.width * 2).rounded(.up))
        #expect(CGFloat(bitmap.width) >= wanted, "the favicon draws from \(bitmap.width) px for \(f.width) pt")
        #expect(f.width == f.height && f.width >= SidebarStyle.kindGlyphSize - 0.5, "the favicon is \(f.size), not the column's glyph size")
    }

    /// A band item draws its favicon through the same favicon path as a workspace row: on the dark sidebar a dark mono
    /// favicon turns into a template in the label colour, and a colourful one keeps its own colours.
    @Test func aBandItemTreatsItsFaviconAsAWorkspaceRowDoes() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        window.contentView = root
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: true)
        for (image, tinted) in [(Self.monoMark(white: false), true), (Self.colourful(), false)] {
            var info = SidebarItemInfo(title: "GitHub", symbol: "globe")
            info.favicon = SidebarFavicon(image)
            let row = SidebarItemRowView(frame: root.bounds)
            root.addSubview(row)
            defer { row.removeFromSuperview() }
            row.configure(info, style: .list)
            row.layoutSubtreeIfNeeded()
            row.updateLayer()
            let shown = try #require(row.icon.image, "the band item shows no favicon")
            #expect(shown.isTemplate == tinted, "a \(tinted ? "dark mono" : "colourful") favicon is\(shown.isTemplate ? "" : " not") a template")
            if tinted { #expect(row.icon.contentTintColor != nil, "the tinted favicon has no ink") }
        }
    }
}
