import AppKit
import ImageIO
@testable import CmuxNextDesign
import Testing

/// Leo, 2026-11-17: "what if you almost treat the background wallpaper like a light source? lighting
/// inside cmux!?" The wallpaper's light field (`appearance.wallpaperLighting`) crosses the app FFI from
/// cmux-motion, and the Swift side places windows and edges in its top-left space.
@MainActor @Suite struct WallpaperLightTests {
    /// A 160 by 100 picture: a navy sky with a warm sun at its upper right.
    private static func dusk() -> CGImage {
        let (width, height) = (160, 100)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.07, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.5, alpha: 1))
        // A CGContext's origin is the bottom left: y 80 is near the top.
        context.fillEllipse(in: CGRect(x: 118, y: 72, width: 16, height: 16))
        return context.makeImage()!
    }

    @Test func theFieldFindsTheSunAndItsWarmRim() throws {
        let field = try #require(WallpaperLightField.read(Self.dusk()))
        #expect(field.key.x > 0.7 && field.key.y < 0.3, "upper right: \(field.key)")
        #expect(field.key.strength > 0.5)
        #expect(field.rim.red > field.rim.blue, "a warm rim: \(field.rim)")
        #expect(abs(field.aspect - 1.6) < 0.001)
    }

    /// AppKit screen coordinates grow upward; the field's grow down. A window at the screen's top
    /// left, under a sun at its upper right, is lit from its right and a little above.
    @Test func aWindowIsLitFromTheSunsSide() throws {
        let field = try #require(WallpaperLightField.read(Self.dusk()))
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let topLeft = CGRect(x: 0, y: 500, width: 600, height: 500)
        let style = try #require(field.style(window: topLeft, screen: screen))
        #expect(style.dx > 0.8, "light from the right: \(style)")
        #expect(style.dy < 0.2, "and not from below: \(style)")
        // A window right under the sun is lit more strongly than one far from it.
        let near = try #require(field.rim(rect: CGRect(x: 1100, y: 600, width: 400, height: 300), container: screen))
        let far = try #require(field.rim(rect: CGRect(x: 0, y: 0, width: 300, height: 200), container: screen))
        #expect(near.alpha > far.alpha)
        #expect(field.style(window: topLeft, screen: .zero) == nil, "no screen size, no style")
    }

    @Test func offSendsNoVariables() {
        var repaints = 0
        let light = WallpaperLight { repaints += 1 }
        light.desktopDidChange(WallpaperLightField.read(Self.dusk()))
        #expect(light.cssVariables.isEmpty)
        #expect(light.pageStyle == nil)
        #expect(repaints == 0, "off: a new picture repaints nothing")
    }

    /// A theme picture's field is read in its decode, once, and found again by the image.
    @Test func aDecodedPictureCarriesItsField() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wallpaper-light-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "dusk.png")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Self.dusk(), nil)
        #expect(CGImageDestinationFinalize(destination))
        let store = BackdropImageStore(maxPixelSize: 160)
        let image = try #require(await store.image(.file(path: file.path)))
        let field = try #require(store.lightField(of: image))
        #expect(field.key.x > 0.7 && field.key.y < 0.3, "the sun, through the decode: \(field.key)")
    }
}
