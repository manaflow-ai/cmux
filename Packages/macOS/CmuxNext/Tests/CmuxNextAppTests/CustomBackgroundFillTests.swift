import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A background the person brings in (Choose Image, a link) fills the whole window at every size,
/// like the bundled art does (`ResizeInvariantTests`). Lawrence, 2026-11-20, on a custom background:
/// it only showed in the bottom left. Leo, 2026-11-21: "we need to make sure we have good controls
/// and settings and everything work sthere in that and teh edge cases are checked".
///
/// The window's backdrop is made at `.zero` and sized by its root's autoresize afterwards
/// (`WindowRootView`), so every layer in it must follow its view's size without a layout pass: a
/// sublayer sized only in `layout()` stays at its first frame, anchored bottom-left.
@MainActor @Suite(.serialized, .closesItsWindows) struct CustomBackgroundFillTests {
    static let sizes: [CGSize] = [
        CGSize(width: 1100, height: 720), CGSize(width: 1512, height: 945), CGSize(width: 640, height: 900),
        CGSize(width: 2672, height: 1522), CGSize(width: 900, height: 560),
    ]

    /// A small picture, smaller than the window in both directions, so a layer that draws it
    /// unscaled from a corner differs from one that fills.
    static func writeImage(width: Int, height: Int, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("custom-\(width)x\(height).png")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)) // colour-allow: a test fixture's pixels
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    @Test(arguments: [(64, 48), (48, 200), (4000, 300)])
    func aCustomPictureFillsTheWindowFromAZeroFrame(width: Int, height: Int) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("custom-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.writeImage(width: width, height: height, in: folder)
        let selection = BackdropSelection.file(path: file.path)
        let images = BackdropImageStore(maxPixelSize: 1600)
        let start = NSRect(origin: .zero, size: Self.sizes[0])
        let window = NSWindow(contentRect: start, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: start)
        window.contentView = root
        // As `WindowRootView` makes it: at `.zero`, then sized by the root.
        let backdrop = WindowMaterialView(frame: .zero, images: images, videos: BackdropVideoPlayers(), fillsWindow: true)
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        window.orderFrontRegardless()
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: selection), tint: .black)
        await backdrop.artLoad?.value
        for size in Self.sizes {
            // The superview's autoresize alone, before any layout pass.
            root.setFrameSize(size)
            #expect(backdrop.bounds.size == size)
            #expect(backdrop.artView.layer?.contents != nil, "the custom picture shows no image at \(size)")
            #expect(backdrop.artView.frame == backdrop.bounds, "the custom picture does not fill the window at \(size)")
            #expect(backdrop.artView.layer?.contentsGravity == .resizeAspectFill)
            // AppKit derives a backing layer's gravity from the view's placement on its own passes:
            // the placement must say the same, or the picture draws unscaled from a corner.
            #expect(backdrop.artView.layerContentsPlacement == .scaleProportionallyToFill,
                    "AppKit's placement for the art view disagrees with its aspect fill")
            #expect(backdrop.videoView.playerLayer.frame == backdrop.videoView.bounds,
                    "a video wallpaper's layer stays at \(backdrop.videoView.playerLayer.frame) in a \(size) window")
            #expect(backdrop.shaderView.metalLayer.frame == backdrop.shaderView.bounds,
                    "a living wallpaper's layer stays at \(backdrop.shaderView.metalLayer.frame) in a \(size) window")
        }
        // A display pass (AppKit's own update of the backing layer) keeps the fill.
        backdrop.artView.needsDisplay = true
        backdrop.displayIfNeeded()
        backdrop.layoutSubtreeIfNeeded()
        #expect(backdrop.artView.layer?.contentsGravity == .resizeAspectFill, "a display pass reset the picture's gravity")
        #expect(backdrop.artView.frame == backdrop.bounds)
    }

    /// The same holds for a pane's own copy of the art (`PaneContentView+Backdrop`), made at the
    /// pane's size at that moment, which may be none yet.
    @Test func aPanesOwnPictureFillsThePaneFromAZeroFrame() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("custom-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.writeImage(width: 64, height: 48, in: folder)
        let images = BackdropImageStore(maxPixelSize: 1600)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = NSView(frame: .zero)
        window.contentView?.addSubview(pane)
        let art = WindowMaterialView(frame: pane.bounds, images: images, videos: BackdropVideoPlayers())
        art.autoresizingMask = [.width, .height]
        pane.addSubview(art)
        window.orderFrontRegardless()
        art.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .file(path: file.path)), tint: .black)
        await art.artLoad?.value
        for size in [CGSize(width: 400, height: 300), CGSize(width: 800, height: 600), CGSize(width: 320, height: 580)] {
            pane.setFrameSize(size)
            #expect(art.artView.frame == art.bounds)
            #expect(art.videoView.playerLayer.frame == art.videoView.bounds)
            #expect(art.shaderView.metalLayer.frame == art.shaderView.bounds)
        }
    }
}
