import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A custom picture under a Frosted window (Opacity below 100 %, Blur above 0) fills the whole
/// window as the window server draws it, not only its bottom-left corner. Leo, 2026-11-23, after
/// lowering his Opacity over his own picture: "ah, it went only to the bottom left. lawrence
/// encountered this issue before. well now we've replicated it. we need to fix this too." and "as
/// in it didnt fill the whole thing".
///
/// `CustomBackgroundFillTests` checks the art view's frame and gravity, which were already right;
/// what reaches the screen is checked here, from the window server's own composite, with the art's
/// blur (``WindowBackdrop/artBlurRadius``) on and off.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(2))) struct BlurredBackgroundFillTests {
    /// A red picture, smaller than the window, so art that does not fill leaves the black window.
    static func writeRedImage(in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("red-160x120.png")
        let context = try #require(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1)) // colour-allow: a test fixture's pixels
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    /// The RGBA of `image` at the fraction (`x`, `y`) of its size, from its top-left.
    static func pixel(_ image: CGImage, x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let px = CGFloat(image.width) * x
        let py = CGFloat(image.height) * (1 - y)
        context?.draw(image, in: CGRect(x: -px, y: -py, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() },
          arguments: [0, 20])
    func aFrostedCustomPictureFillsTheWholeWindowOnScreen(blur: Int) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blur-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.writeRedImage(in: folder)
        let images = BackdropImageStore(maxPixelSize: 1600)
        let start = NSRect(x: 80, y: 80, width: 480, height: 320)
        let window = NSWindow(contentRect: start, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        defer { window.close() }
        let root = NSView(frame: NSRect(origin: .zero, size: start.size))
        root.wantsLayer = true
        window.contentView = root
        // As `WindowRootView` makes it: at `.zero`, then sized by the root.
        let backdrop = WindowMaterialView(frame: .zero, images: images, videos: BackdropVideoPlayers(), fillsWindow: true)
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        window.orderFrontRegardless()
        // Frosted at Opacity 0.4: the tint lets most of the picture through.
        var frosted = WindowBackdrop(backgroundOpacity: 0.4, backgroundBlur: max(blur, 1), liquidGlass: false)
        frosted.selection = .file(path: file.path)
        frosted.artBlurRadius = blur
        backdrop.apply(frosted, tint: .black)
        await backdrop.artLoad?.value
        #expect(backdrop.artBlurRadius == blur)
        for size in [start.size, CGSize(width: 720, height: 460)] {
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
            var shot: CGImage?
            for _ in 0..<20 {
                CATransaction.flush()
                try? await Task.sleep(for: .milliseconds(100))
                shot = window.compositedSnapshot()
                if let shot, shot.width > 0 { break }
            }
            let image = try #require(shot, "no capture of the window at \(size)")
            // Every quarter of the window shows the red picture under the tint, the far corners too.
            for (x, y) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75), (0.95, 0.05), (0.05, 0.95), (0.95, 0.95)] {
                let color = Self.pixel(image, x: x, y: y)
                #expect(color.r > color.g + 40 && color.r > color.b + 40,
                        "blur \(blur), \(size): no picture at (\(x), \(y)) of the window: \(color) in a \(image.width)x\(image.height) capture")
            }
        }
    }
}
