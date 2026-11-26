import CoreGraphics
@testable import MessagesLabSidebar
import Testing

/// cmux: a picture avatar with clear edges is fitted by what it draws (the user, 2026-11-24: the Chief's pet sat high in
/// its pinned slab and read too small): centred on its opaque pixels and grown to span 84 % of the avatar.
struct PictureAvatarCentreTests {
    /// A 100 x 100 picture with an opaque square at `rect` (top-left origin).
    private func picture(opaque rect: CGRect) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: rect.minX, y: 100 - rect.maxY, width: rect.width, height: rect.height)) // CG is y up
        return try #require(ctx.makeImage())
    }

    /// Where `art` (top-left fractions of the canvas) lands when the picture is drawn in `rect` (y up).
    private func drawn(_ art: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + art.minX * rect.width, y: rect.minY + (1 - art.maxY) * rect.height,
               width: art.width * rect.width, height: art.height * rect.height)
    }

    @Test(arguments: [CGRect(x: 25, y: 10, width: 50, height: 50), CGRect(x: 0, y: 25, width: 50, height: 50),
                      CGRect(x: 40, y: 50, width: 30, height: 45)])
    func artWithClearEdgesIsCentredAndGrown(_ art: CGRect) throws {
        let size = CGSize(width: 88, height: 88)
        let fit = pictureFit(try picture(opaque: art), size: size)
        #expect(fit.clearEdges)
        let box = drawn(CGRect(x: art.minX / 100, y: art.minY / 100, width: art.width / 100, height: art.height / 100), in: fit.rect)
        #expect(abs(box.midX - 44) <= 2 && abs(box.midY - 44) <= 2, "the art's middle at \(box.midX), \(box.midY)")
        #expect(abs(max(box.width, box.height) - 0.84 * 88) <= 3, "the art spans \(max(box.width, box.height)) pt")
    }

    @Test func tinyArtGrowsAtMostThreeTimes() throws {
        let fit = pictureFit(try picture(opaque: CGRect(x: 45, y: 45, width: 10, height: 10)), size: CGSize(width: 88, height: 88))
        #expect(abs(fit.rect.width - 3 * 88) < 0.5)
    }

    /// An icon with a thin clear padding is a picture to crop round, not art to fit.
    @Test func aThinMarginIsDrawnAsItIs() throws {
        let fit = pictureFit(try picture(opaque: CGRect(x: 3, y: 3, width: 94, height: 94)), size: CGSize(width: 88, height: 88))
        #expect(!fit.clearEdges && fit.rect == CGRect(x: 0, y: 0, width: 88, height: 88))
    }

    @Test func aFullPictureIsDrawnAsItIs() throws {
        let fit = pictureFit(try picture(opaque: CGRect(x: 0, y: 0, width: 100, height: 100)), size: CGSize(width: 88, height: 88))
        #expect(!fit.clearEdges && fit.rect == CGRect(x: 0, y: 0, width: 88, height: 88))
    }
}
