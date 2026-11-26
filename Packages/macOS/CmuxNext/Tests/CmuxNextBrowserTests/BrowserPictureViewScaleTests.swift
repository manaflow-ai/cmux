import AppKit
@testable import CmuxNextBrowser
import Testing

/// cmux#57419: a page's last picture (a hibernated tab's placeholder, the stand-in over a woken or restored page until
/// it paints) was stretched to the pane. A picture taken at another pane size drew the page's text at the wrong size,
/// and one with fewer pixels than the pane drew it blurry until the page painted. It is now drawn top-left at its own
/// size, one picture pixel per backing pixel, as Chromium shows a page's last frame while its pane changes size.
@MainActor @Suite struct BrowserPictureViewScaleTests {
    private static let pane = CGSize(width: 400, height: 300)

    /// A picture `points` large at `scale` pixels per point, opaque blue.
    private static func picture(points: CGSize, scale: CGFloat) throws -> CGImage {
        let width = Int(points.width * scale), height = Int(points.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The view's layer drawn at one pixel per point, read back as RGBA rows from the top.
    private static func rendered(_ view: NSView) throws -> (alphaAt: (CGPoint) -> UInt8, size: CGSize) {
        let layer = try #require(view.layer)
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        layer.render(in: context)
        let image = try #require(context.makeImage())
        let data = try #require(image.dataProvider?.data as Data?)
        let rowBytes = image.bytesPerRow
        return ({ point in
            // `point` in view coordinates from the top-left; the bitmap's rows run from the top.
            let x = Int(point.x), row = Int(point.y)
            return data[row * rowBytes + x * 4 + 3]
        }, view.bounds.size)
    }

    private static func window(showing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: pane), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: pane))
        window.contentView = content
        view.frame = content.bounds
        content.addSubview(view)
        return window
    }

    @Test func aPictureOfASmallerPaneIsDrawnTopLeftAtItsOwnSizeNotStretched() throws {
        let view = BrowserPictureView(picture: { nil })
        let window = Self.window(showing: view)
        defer { window.close() }
        let scale = view.pixelsPerPoint
        // The page pictured when its pane was half as wide and half as tall as now.
        let shown = BrowserPictureView(decoded: try Self.picture(points: CGSize(width: 200, height: 150), scale: scale))
        view.addSubview(shown)
        shown.frame = view.bounds
        let layer = try #require(shown.layer)
        #expect(layer.contentsGravity == .topLeft, "the picture is stretched to the pane (\(layer.contentsGravity.rawValue))")
        #expect(layer.contentsScale == scale, "the picture is drawn at \(layer.contentsScale) pixels per point, not the window's \(scale)")
        let image = try Self.rendered(shown)
        #expect(image.alphaAt(CGPoint(x: 20, y: 20)) == 255, "the picture's top-left corner is not at the pane's")
        #expect(image.alphaAt(CGPoint(x: 190, y: 140)) == 255, "the picture does not reach its own size")
        #expect(image.alphaAt(CGPoint(x: 300, y: 40)) == 0, "the picture was stretched wider than it was taken")
        #expect(image.alphaAt(CGPoint(x: 40, y: 250)) == 0, "the picture was stretched taller than it was taken")
        #expect(image.alphaAt(CGPoint(x: 380, y: 280)) == 0, "the picture was stretched over the whole pane")
    }

    @Test func aPictureOfThisPaneCoversItExactly() throws {
        let host = NSView(frame: .zero)
        let window = Self.window(showing: host)
        defer { window.close() }
        let picture = try Self.picture(points: Self.pane, scale: window.backingScaleFactor)
        let view = BrowserPictureView(decoded: picture)
        host.addSubview(view)
        view.frame = host.bounds
        let image = try Self.rendered(view)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 398, y: 1), CGPoint(x: 1, y: 298), CGPoint(x: 398, y: 298)] {
            #expect(image.alphaAt(point) == 255, "the pane's own picture leaves \(point) uncovered")
        }
        #expect(view.decodedPicture === picture)
    }

    /// A picture keeps its own pixels per point, not the window's: one taken on a display of another scale, or a
    /// hover card thumbnail standing in for a page with no full-size frame, is drawn over the page area it pictures.
    @Test func aPictureIsDrawnAtItsOwnScaleNotTheWindows() throws {
        let host = NSView(frame: .zero)
        let window = Self.window(showing: host)
        defer { window.close() }
        // A picture of this pane at 1 pixel per point, on any display.
        let single = BrowserPictureView(decoded: try Self.picture(points: Self.pane, scale: 1), scale: 1)
        host.addSubview(single)
        single.frame = host.bounds
        #expect(single.layer?.contentsScale == 1)
        #expect(try Self.rendered(single).alphaAt(CGPoint(x: 398, y: 298)) == 255, "a 1x picture of the pane does not cover it")
        // A 320 px thumbnail of the 400 pt pane: 0.8 pixels per point, filling it.
        let thumbnail = try Self.picture(points: CGSize(width: 320, height: 240), scale: 1)
        let small = BrowserPictureView(picture: { thumbnail }, scale: { 0.8 })
        host.addSubview(small)
        small.frame = host.bounds
        #expect(small.pixelsPerPoint == 0.8)
    }
}
