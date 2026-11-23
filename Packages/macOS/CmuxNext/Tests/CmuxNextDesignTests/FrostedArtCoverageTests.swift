import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Leo, 2026-11-23, Frosted over Desktop Wallpaper on a 2x display: "it went only to the bottom
/// left", "as in it didnt fill the whole thing" (cmux#51381). On a Retina screen the live
/// `CIAffineClamp` + `CIGaussianBlur` layer filter on the art covered the bottom half, and after a
/// resize only the bottom-left quadrant (scripts/measure/frosted-art-2x.sh on a MacBook's built-in
/// Retina display); nothing tested the art at 2x. A still is now blurred into its own picture: these
/// render the art layer at a 2x backing and check every quadrant, before and after a resize.
@MainActor @Suite struct FrostedArtCoverageTests {
    /// A 4 px black and white checkerboard: sharp where unblurred, an even gray once blurred.
    static func checkerboard(width: Int, height: Int) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) where (x / 4 + y / 4).isMultiple(of: 2) {
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return try #require(ctx.makeImage())
    }

    struct Quadrant: CustomStringConvertible {
        var covered = 0, blurred = 0, samples = 0
        var description: String { "covered \(covered)/\(samples), blurred \(blurred)/\(samples)" }
    }

    /// `layer` drawn into a bitmap at `scale` pixels per point over a transparent ground; per
    /// quadrant, how many samples it covers and how many are blurred (no sharp step to the
    /// sample beside them, mid gray).
    static func quadrants(of layer: CALayer, scale: CGFloat) throws -> [String: Quadrant] {
        let width = Int(layer.bounds.width * scale), height = Int(layer.bounds.height * scale)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        var out: [String: Quadrant] = [:]
        for y in stride(from: 2, to: height - 4, by: 5) {
            for x in stride(from: 2, to: width - 4, by: 5) {
                let name = (y < height / 2 ? "T" : "B") + (x < width / 2 ? "L" : "R")
                let i = (y * width + x) * 4, j = (y * width + x + 2) * 4
                var q = out[name] ?? Quadrant()
                q.samples += 1
                if pixels[i + 3] > 250 { q.covered += 1 }
                let lum = Int(pixels[i]), next = Int(pixels[j])
                if pixels[i + 3] > 250, abs(lum - next) < 24, (60...200).contains(lum) { q.blurred += 1 }
                out[name] = q
            }
        }
        return out
    }

    static func expectFilled(_ layer: CALayer, scale: CGFloat, _ when: String) throws {
        let quadrants = try quadrants(of: layer, scale: scale)
        #expect(quadrants.count == 4)
        for (name, q) in quadrants {
            #expect(q.covered == q.samples, "\(when) at \(scale)x: \(name) \(q)")
            #expect(q.blurred * 100 >= q.samples * 95, "\(when) at \(scale)x: \(name) \(q)")
        }
    }

    /// The blur keeps the picture's whole extent and aspect, shrunk only where the blur hides it.
    @Test func theBlurredPictureKeepsTheWholePicture() throws {
        let board = try Self.checkerboard(width: 3024, height: 1964)
        for scale in [1.0, 2.0] as [CGFloat] {
            for fill in [CGSize(width: 900, height: 560), CGSize(width: 1512, height: 982), CGSize(width: 400, height: 900)] {
                let blurred = try #require(BackdropArtBlur.blurred(board, radius: 20, fill: fill, scale: scale))
                let aspect = Double(blurred.width) / Double(blurred.height)
                #expect(abs(aspect - 3024.0 / 1964.0) < 0.02, "\(fill) at \(scale)x: \(blurred.width)x\(blurred.height)")
                #expect(blurred.width <= board.width && blurred.height <= board.height)
            }
        }
        #expect(BackdropArtBlur.blurred(board, radius: 0, fill: CGSize(width: 900, height: 560), scale: 2) == nil)
    }

    /// Frosted over a picture fills the whole art layer, blurred, in all four quadrants at 2x (and
    /// 1x), before and after the window grows; the art layer itself carries no filter.
    @Test func frostedFillsEveryQuadrantAt2xThroughAResize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frosted-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("board.png")
        let dest = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try Self.checkerboard(width: 1512, height: 982), nil)
        #expect(CGImageDestinationFinalize(dest))

        var input = ThemeInput.ghosttyDefault
        input.backgroundBlur = 20
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 450, height: 280),
                                      images: BackdropImageStore(maxPixelSize: 1600), videos: BackdropVideoPlayers())
        view.apply(WindowBackdrop(ThemeTokens.derive(from: input), selection: .file(path: file.path)), tint: .black)
        await view.artLoad?.value
        await view.artBlur.task?.value
        let art = try #require(view.artView.layer)
        #expect(view.artBlurRadius == 20)
        #expect((art.filters ?? []).isEmpty, "a still blurs into its own picture, never a layer filter")
        #expect((art.contents as AnyObject?) !== view.artImage, "the art layer shows the blurred copy")
        try Self.expectFilled(art, scale: 2, "450x280")
        try Self.expectFilled(art, scale: 1, "450x280")

        // Past the tolerance the blur is made again for the new size; the layer fills it either way.
        view.setFrameSize(NSSize(width: 1100, height: 700))
        try Self.expectFilled(art, scale: 2, "1100x700 before its new blur")
        await view.artBlur.task?.value
        try Self.expectFilled(art, scale: 2, "1100x700")

        // Blur off: the sharp picture itself, still no filter.
        input.backgroundBlur = 0
        view.apply(WindowBackdrop(ThemeTokens.derive(from: input), selection: .file(path: file.path)), tint: .black)
        #expect((art.contents as AnyObject?) === view.artImage)
        #expect((art.filters ?? []).isEmpty)
    }

    /// A video or living wallpaper changes every frame, so it keeps a live blur: the blur alone (the
    /// clamp before it was what filled only the bottom left at 2x), on a view that runs the blur's
    /// reach past every edge of a clip, so no fading rim shows. Off, it sits at the clip's bounds.
    @Test func liveWallpapersBlurWithoutAClampPastTheClip() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                      images: BackdropImageStore(maxPixelSize: 64), videos: BackdropVideoPlayers())
        var input = ThemeInput.ghosttyDefault
        input.backgroundBlur = 20
        view.apply(WindowBackdrop(ThemeTokens.derive(from: input), selection: .art(.vanGoghStarryNight)), tint: .black)
        #expect(view.liveArtClip.layer?.masksToBounds == true)
        for live in [view.videoView as NSView, view.shaderView as NSView] {
            let names = (live.layer?.filters as? [CIFilter])?.map(\.name) ?? []
            #expect(names == ["CIGaussianBlur"], "\(live): \(names)")
            #expect(live.superview === view.liveArtClip)
            #expect(live.frame == view.liveArtClip.bounds.insetBy(dx: -60, dy: -60))
        }
        // The outset follows a resize.
        view.setFrameSize(NSSize(width: 900, height: 600))
        #expect(view.videoView.frame == view.liveArtClip.bounds.insetBy(dx: -60, dy: -60))
        input.backgroundBlur = 0
        view.apply(WindowBackdrop(ThemeTokens.derive(from: input), selection: .art(.vanGoghStarryNight)), tint: .black)
        for live in [view.videoView as NSView, view.shaderView as NSView] {
            #expect((live.layer?.filters ?? []).isEmpty)
            #expect(live.frame == view.liveArtClip.bounds)
        }
    }
}
