import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// Frosted over a picture fills the whole window, as the unblurred picture does
/// (`CustomBackgroundFillTests`). Leo, 2026-11-23, Frosted over his background picture: "ah, it went
/// only to the bottom left. lawrence encountered this issue before. well now we've replicated it. we
/// need to fix this too."
///
/// Frosted is the one backdrop that blurs the art itself (``WindowBackdrop/artBlurRadius``). Layer
/// frames cannot show where the render server puts the blurred picture, so these tests render the
/// backdrop's real art layer at 2x and read the pixels back, per quadrant.
@MainActor @Suite(.serialized) struct FrostedArtFillTests {
    /// Points of the rendered backdrop; the render is at 2x, like a Retina window.
    static let size = CGSize(width: 400, height: 300)
    static let scale: CGFloat = 2

    /// The fraction of each quadrant's pixels the picture covers (alpha over 0.5), in the order
    /// bottom-left, bottom-right, top-left, top-right (layer coordinates, y up).
    struct Coverage: CustomStringConvertible {
        var quadrants: [Double]
        var description: String {
            "BL \(Self.pct(quadrants[0])) BR \(Self.pct(quadrants[1])) TL \(Self.pct(quadrants[2])) TR \(Self.pct(quadrants[3]))"
        }
        static func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        var everyQuadrantCovered: Bool { quadrants.allSatisfy { $0 > 0.95 } }
    }

    /// Renders `layer` (sized in points) into a 2x bitmap and measures where it drew. A
    /// `CARenderer` into a Metal texture drew nothing at all on a fleet Mac (every quadrant 0%,
    /// the unfiltered baseline included), so this draws with `CALayer.render(in:)`, which honours
    /// contents and their gravity. It ignores `filters`: these tests measure the art layer, which
    /// carries none.
    static func render(_ layer: CALayer) throws -> Coverage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        let data = try #require(context.data)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // Bitmap rows run top to bottom: row 0 is the top of the layer.
        var covered = [Int](repeating: 0, count: 4)
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[(y * width + x) * 4 + 3] > 127 {
                let top = y < height / 2, right = x >= width / 2
                covered[(top ? 2 : 0) + (right ? 1 : 0)] += 1
            }
        }
        let quadrant = Double(width * height / 4)
        return Coverage(quadrants: covered.map { Double($0) / quadrant })
    }

    /// A picture smaller than the window, so one drawn unscaled from a corner covers only it.
    static func picture(width: Int, height: Int) throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)) // colour-allow: a test fixture's pixels
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    /// Frosted tokens: Opacity below 1 and a positive `background-blur`.
    static func frostedTokens(blur: Int = 20) -> ThemeTokens {
        var tokens = ThemeTokens.derive(from: .ghosttyDefault)
        tokens.backgroundOpacity = 0.7
        tokens.backgroundBlur = blur
        return tokens
    }

    /// The window's backdrop under Frosted over a picture: the art layer alone (the tint and the
    /// material are hidden for this measurement) covers every quadrant.
    @Test(arguments: [(64, 48), (1600, 1000), (4000, 300)])
    func frostedArtFillsEveryQuadrant(width: Int, height: Int) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("frosted-art-\(UUID().uuidString)",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try CustomBackgroundFillTests.writeImage(width: width, height: height, in: folder)
        let images = BackdropImageStore(maxPixelSize: 1600)
        let backdrop = WindowMaterialView(frame: CGRect(origin: .zero, size: Self.size), images: images,
                                          videos: BackdropVideoPlayers(), fillsWindow: true)
        backdrop.wantsLayer = true
        let frosted = WindowBackdrop(Self.frostedTokens(), selection: .file(path: file.path))
        #expect(frosted.material == .frosted)
        #expect(frosted.artBlurRadius == 20)
        backdrop.apply(frosted, tint: .black)
        await backdrop.artLoad?.value
        await backdrop.artBlurJob?.value
        let art = try #require(backdrop.artView.layer)
        #expect(art.contents != nil, "the picture never loaded")
        art.contentsScale = Self.scale
        art.removeFromSuperlayer()
        let coverage = try Self.render(art)
        print("FrostedArtFillTests \(width)x\(height) frosted art: \(coverage)")
        #expect(coverage.everyQuadrantCovered, "Frosted over a \(width)x\(height) picture covers only \(coverage)")
    }

    /// The same picture unblurred, the path #48469 fixed: the baseline the frosted one must match.
    @Test func unblurredArtFillsEveryQuadrant() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("frosted-art-\(UUID().uuidString)",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try CustomBackgroundFillTests.writeImage(width: 64, height: 48, in: folder)
        let backdrop = WindowMaterialView(frame: CGRect(origin: .zero, size: Self.size),
                                          images: BackdropImageStore(maxPixelSize: 1600),
                                          videos: BackdropVideoPlayers(), fillsWindow: true)
        backdrop.wantsLayer = true
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .file(path: file.path)), tint: .black)
        await backdrop.artLoad?.value
        let art = try #require(backdrop.artView.layer)
        art.contentsScale = Self.scale
        art.removeFromSuperlayer()
        let coverage = try Self.render(art)
        print("FrostedArtFillTests 64x48 unblurred art: \(coverage)")
        #expect(coverage.everyQuadrantCovered, "the unblurred picture covers only \(coverage)")
    }
}
