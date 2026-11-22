import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-27 ("dialog sides has weird bg"): the browser's save-password bar showed
/// gray squares past its rounded glass corners. `NSGlassEffectView` never clips its content
/// view, and the bar's content paints a veil (`OverlayBackingView`) edge to edge, so the veil
/// drew a square card behind the rounded glass. The surface clips its content to its shape on
/// every material, so a content background never shows past the corners.
@MainActor @Suite(.serialized, .closesItsWindows) struct OverlaySurfaceCornerTests {
    /// The content view of a surface of `material`, its content painting opaque red edge to
    /// edge, rendered to RGBA. The surface is hosted in an offscreen window (a view outside a
    /// window never draws its layers). The content view's own layer is rendered, not the
    /// surface's: `NSGlassEffectView` draws nothing through `CALayer.render(in:)`, and the
    /// content's clip is exactly what the glass does not give it.
    static func render(_ material: OverlayMaterial, radius: CGFloat = 16) throws -> (pixel: (Int, Int) -> (r: UInt8, a: UInt8), width: Int, height: Int) {
        let rect = NSRect(x: 0, y: 0, width: 200, height: 64)
        let window = NSWindow(contentRect: rect.offsetBy(dx: -10_000, dy: -10_000), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: rect)
        host.wantsLayer = true
        window.contentView = host
        let surface = OverlaySurfaceView(material: material, interactive: true, cornerRadius: radius)
        surface.frame = rect
        host.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        let fill = NSView(frame: surface.contentView.bounds)
        fill.wantsLayer = true
        fill.autoresizingMask = [.width, .height]
        fill.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
        surface.contentView.addSubview(fill)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let layer = try #require(surface.contentView.layer)
        layer.layoutIfNeeded()
        let width = Int(surface.contentView.bounds.width.rounded()), height = Int(surface.contentView.bounds.height.rounded())
        try #require(width > 40 && height > 20, "the content view fills the surface")
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            layer.render(in: context)
        }
        return ({ x, y in let i = (y * width + x) * 4; return (bytes[i], bytes[i + 3]) }, width, height)
    }

    /// The content's own red shows inside the shape and never in the corner squares outside it.
    @Test(arguments: [OverlayMaterial.liquidGlass, .vibrancy, .opaque])
    func contentBackgroundStaysInsideTheRoundedShape(_ material: OverlayMaterial) throws {
        let image = try Self.render(material)
        let center = image.pixel(image.width / 2, image.height / 2)
        #expect(center.r > 200 && center.a > 200, "the content's background shows inside the surface")
        for (x, y) in [(1, 1), (image.width - 2, 1), (1, image.height - 2), (image.width - 2, image.height - 2)] {
            let corner = image.pixel(x, y)
            #expect(!(corner.r > 200 && corner.a > 200), "content background paints the corner at (\(x), \(y)) outside the rounded shape")
        }
    }

    /// The clip follows a radius change (density changes it live on the browser's bars).
    @Test func contentClipFollowsTheCornerRadius() {
        let surface = OverlaySurfaceView(material: .liquidGlass, interactive: true, cornerRadius: 8)
        surface.cornerRadius = 20
        #expect(surface.contentView.layer?.cornerRadius == 20)
        #expect(surface.contentView.layer?.masksToBounds == true)
    }
}
