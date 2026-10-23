import AppKit
@testable import CmuxNextDesign
import Metal
import QuartzCore
import Testing
import CmuxNextDesignTokens

/// `cmux window|pane|tab screenshot` reads the app's own window without the
/// Screen Recording grant (`NSWindow.screenshotImage`). The window here has
/// a plain green view and a red CAMetalLayer view (the way Ghostty draws a
/// terminal), and sits behind another window of this process: the PNG must
/// be the window's full pixel size and show both colors, Metal included, not
/// a blank or covered image. Each capture path is checked on its own, so a
/// red run says which one gives real Metal pixels.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WindowScreenshotTests {
    /// A layer-hosting view whose CAMetalLayer is cleared to red once.
    private final class MetalView: NSView {
        let metal = CAMetalLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            metal.device = MTLCreateSystemDefaultDevice()
            metal.pixelFormat = .bgra8Unorm
            metal.isOpaque = true
            layer = metal
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// Clears the next drawable to red and presents it.
        func drawRed(scale: CGFloat) -> Bool {
            metal.contentsScale = scale
            metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard let device = metal.device, let queue = device.makeCommandQueue(), let drawable = metal.nextDrawable(),
                  let buffer = queue.makeCommandBuffer() else { return false }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
            buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            return true
        }
    }

    /// Whether AppKit can put a window on screen here: a fleet worker
    /// whose user session has no window server (logged out, at the login
    /// window) cannot, and no capture path can be checked on it.
    static func hostShowsWindows() -> Bool {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { return false }
        let probe = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        defer { probe.close() }
        probe.orderFrontRegardless()
        return probe.isVisible && probe.windowNumber > 0
    }

    private struct Fixture {
        let window: NSWindow
        let cover: NSWindow
        let plain: NSView
        let metal: MetalView

        func close() {
            cover.close()
            window.close()
        }
    }

    /// The window under test (green left half, Metal red right half) with an
    /// opaque blue window of this process on top of it.
    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let frame = CGRect(x: 160, y: 160, width: 240, height: 120)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let plain = NSView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        plain.wantsLayer = true
        plain.layer?.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor
        let metal = MetalView(frame: CGRect(x: 120, y: 0, width: 120, height: 120))
        content.addSubview(plain)
        content.addSubview(metal)
        window.contentView = content
        window.orderFrontRegardless()
        let cover = NSWindow(contentRect: frame.insetBy(dx: -20, dy: -20), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        cover.orderFrontRegardless()
        try #require(metal.drawRed(scale: window.backingScaleFactor), "no Metal device or drawable on this host")
        CATransaction.flush()
        return Fixture(window: window, cover: cover, plain: plain, metal: metal)
    }

    /// The pixel at `point` (bottom-left origin, points) of an image of an
    /// area `size` points large.
    private func pixel(_ image: CGImage, at point: CGPoint, size: CGSize) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let scale = CGFloat(image.width) / size.width
        let x = Int(point.x * scale), y = Int((size.height - point.y) * scale)
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Draw so the wanted pixel lands on the context's only pixel.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    private func isRed(_ pixel: (red: Int, green: Int, blue: Int, alpha: Int)) -> Bool {
        pixel.red > 180 && pixel.green < 90 && pixel.blue < 90 && pixel.alpha > 200
    }

    private func isGreen(_ pixel: (red: Int, green: Int, blue: Int, alpha: Int)) -> Bool {
        pixel.green > 180 && pixel.red < 90 && pixel.blue < 90 && pixel.alpha > 200
    }

    /// Captures with `capture` until the Metal frame shows (the window
    /// server composites a presented drawable on its next frame), bounded.
    private func settledImage(_ fixture: Fixture, _ capture: () async throws -> CGImage?) async throws -> CGImage? {
        let deadline = ContinuousClock.now + .seconds(5)
        var last: CGImage?
        repeat {
            last = try await capture()
            if let last, isRed(pixel(last, at: CGPoint(x: 180, y: 60), size: fixture.window.frame.size)) { return last }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return last
    }

    /// `exactSize`: the image is frame x backing scale pixels (the
    /// screenshot's contract). The raw window-server image may differ by a
    /// few pixels on a virtual display, so it is only checked for the
    /// window's aspect ratio.
    private func expectWindowPixels(_ image: CGImage?, _ fixture: Fixture, path: String, exactSize: Bool = true) throws {
        let image = try #require(image, "\(path) gave no image")
        let window = fixture.window
        if exactSize {
            #expect(image.width == Int((window.frame.width * window.backingScaleFactor).rounded()), "\(path) width")
            #expect(image.height == Int((window.frame.height * window.backingScaleFactor).rounded()), "\(path) height")
        } else {
            let expected = Double(image.width) * window.frame.height / window.frame.width
            #expect(abs(Double(image.height) - expected) <= 2, "\(path) is \(image.width) x \(image.height), not the window's shape")
        }
        #expect(!image.isFullyTransparent, "\(path) is blank")
        let metal = pixel(image, at: CGPoint(x: 180, y: 60), size: window.frame.size)
        #expect(isRed(metal), "\(path): the Metal layer came out \(metal), not red")
        let plain = pixel(image, at: CGPoint(x: 60, y: 60), size: window.frame.size)
        #expect(isGreen(plain), "\(path): the plain view came out \(plain), not green (covered or blank)")
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func theScreenshotIsTheCoveredWindowWithItsMetalPixels() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let image = try await settledImage(fixture) { try await fixture.window.screenshotImage() }
        try expectWindowPixels(image, fixture, path: "screenshotImage")
        let png = try #require(image?.pngData())
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect(decoded.pixelsWide == image?.width)
        #expect(decoded.pixelsHigh == image?.height)
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func theWindowServerImageShowsMetalPixels() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let image = try await settledImage(fixture) { fixture.window.compositedSnapshot() }
        try expectWindowPixels(image, fixture, path: "CGWindowListCreateImage", exactSize: false)
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func screenCaptureKitsOwnProcessImageShowsMetalPixels() async throws {
        guard #available(macOS 14.4, *) else { return }
        let fixture = try fixture()
        defer { fixture.close() }
        let image = try await settledImage(fixture) { await fixture.window.screenCaptureKitSnapshot() }
        try expectWindowPixels(image, fixture, path: "ScreenCaptureKit currentProcess")
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func aPaneIsCroppedFromItsWindow() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        let window = fixture.window
        let full = try #require(try await settledImage(fixture) { try await window.screenshotImage() })
        let rect = fixture.metal.convert(fixture.metal.bounds, to: nil)
        let crop = try #require(full.cropped(toWindowRect: rect, windowSize: window.frame.size))
        #expect(crop.width == Int((rect.width * window.backingScaleFactor).rounded()))
        #expect(crop.height == Int((rect.height * window.backingScaleFactor).rounded()))
        // The crop is all Metal red: its center and a corner.
        #expect(isRed(pixel(crop, at: CGPoint(x: rect.width / 2, y: rect.height / 2), size: rect.size)))
        #expect(isRed(pixel(crop, at: CGPoint(x: 2, y: 2), size: rect.size)))
        #expect(full.cropped(toWindowRect: CGRect(x: 400, y: 400, width: 20, height: 20), windowSize: window.frame.size) == nil)
    }

    @Test func aWindowNotOnScreenIsRefusedNotBlank() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        await #expect(throws: WindowScreenshotFailure.notOnScreen) { try await window.screenshotImage() }
    }
}
