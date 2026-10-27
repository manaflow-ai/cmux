import AppKit
@testable import CmuxNextDesign
import Foundation
import ImageIO
import os
import Testing

/// Leo, 2026-10-20: "where is the background auto switching like your macOS background?" Where the
/// desktop shows through the window, the theme tint takes the desktop picture's hue
/// (`appearance.wallpaperTint`) and follows it to a new picture or Space.
@MainActor @Suite struct WallpaperTintTests {
    private nonisolated static let blue = WallpaperTint(red: 0.15, green: 0.3, blue: 0.75)
    private nonisolated static let red = WallpaperTint(red: 0.8, green: 0.2, blue: 0.15)
    private static let darkGrey = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)

    private static func hsb(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        let rgb = color.usingColorSpace(.sRGB)!
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness, alpha)
    }

    // MARK: The blend

    /// A neutral theme takes the picture's hue at its own brightness and alpha: text contrast and
    /// the glass's opacity stay the theme's and the Opacity setting's.
    @Test func aNeutralThemeTakesThePicturesHueAtItsOwnBrightness() {
        for alpha in [1.0, 0.55] {
            let theme = Self.darkGrey.withAlphaComponent(alpha)
            let leaned = Self.blue.blended(into: theme).usingColorSpace(.sRGB)!
            #expect(leaned.blueComponent > leaned.redComponent + 0.01, "leans blue: \(leaned)")
            let (hue, saturation, brightness, leanedAlpha) = Self.hsb(leaned)
            #expect(abs(brightness - 0.12) < 0.005)
            #expect(abs(leanedAlpha - alpha) < 0.0001, "never more opaque than the theme asks")
            #expect(saturation > 0.1 && saturation <= CGFloat(WallpaperTint.saturationCap))
            #expect(abs(hue - Self.hsb(NSColor(srgbRed: 0.15, green: 0.3, blue: 0.75, alpha: 1)).hue) < 0.01)
        }
        // A light theme leans the same way, staying light.
        let light = Self.red.blended(into: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)).usingColorSpace(.sRGB)!
        #expect(light.redComponent > light.blueComponent + 0.01)
        #expect(abs(Self.hsb(light).brightness - 0.96) < 0.005)
    }

    /// A vivid wallpaper tints, it never paints: the picture brings at most the cap's saturation,
    /// mixed in halfway.
    @Test func aVividPictureOnlyTints() {
        let vivid = WallpaperTint(red: 0, green: 0, blue: 1)
        let leaned = vivid.blended(into: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        #expect(Self.hsb(leaned).saturation <= CGFloat(WallpaperTint.saturationCap * WallpaperTint.strength) + 0.01)
    }

    /// A strongly colored theme keeps its own color; a grey picture adds no hue.
    @Test func aColoredThemeKeepsItsColor() {
        let purple = NSColor(srgbRed: 0.35, green: 0.1, blue: 0.5, alpha: 1)
        let leaned = Self.red.blended(into: purple).usingColorSpace(.sRGB)!
        let original = purple.usingColorSpace(.sRGB)!
        #expect(abs(leaned.redComponent - original.redComponent) < 0.0001)
        #expect(abs(leaned.blueComponent - original.blueComponent) < 0.0001)
        let grey = WallpaperTint(red: 0.4, green: 0.4, blue: 0.4).blended(into: Self.darkGrey)
        #expect(Self.hsb(grey).saturation < 0.01)
    }

    /// The tint leans only with the setting on, where the desktop shows through: not on an opaque
    /// window (Reduce Transparency) and not over other art; the Desktop Wallpaper background is
    /// the desktop itself, so it leans too.
    @Test func theTintLeansOnlyWhereTheDesktopShows() {
        let lean = { (enabled: Bool, material: WindowMaterial, shown: BackdropSelection?, wallpaper: WallpaperTint?) in
            WallpaperTint.tint(Self.darkGrey, wallpaper: wallpaper, enabled: enabled, material: material, shown: shown) != Self.darkGrey
        }
        for material: WindowMaterial in [.glass(.regular), .glass(.clear), .frosted, .translucent] {
            #expect(lean(true, material, nil, Self.blue))
            #expect(lean(true, material, .desktop, Self.blue))
            #expect(!lean(false, material, nil, Self.blue))
            #expect(!lean(true, material, nil, nil))
            #expect(!lean(true, material, .art(BackdropArt.allCases[0]), Self.blue))
            #expect(!lean(true, material, .file(path: "/tmp/mine.png"), Self.blue))
        }
        #expect(!lean(true, .opaque, nil, Self.blue))
    }

    /// The picture's color is its mean: half red, half blue averages to purple.
    @Test func thePicturesColorIsItsMean() throws {
        let image = try Self.image(width: 8, height: 4) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
        }
        let mean = try #require(WallpaperTint.average(of: image))
        #expect(abs(mean.red - 0.5) < 0.03 && mean.green < 0.03 && abs(mean.blue - 0.5) < 0.03)
    }

    // MARK: Following the desktop

    /// Each new picture is sampled once: a Space switch to the same picture costs nothing, a new
    /// picture (or Space with its own) takes its color, and switching back reuses the first color.
    @Test func theWatchFollowsANewPictureAndReusesAKnownOne() async throws {
        let folder = try Self.folder()
        let bluePicture = try Self.writePicture(Self.blue, named: "blue.png", in: folder)
        let redPicture = try Self.writePicture(Self.red, named: "red.png", in: folder)
        var shown = bluePicture
        let watch = DesktopWallpaperWatch(read: { Self.reading(shown, folder: folder) }, sample: DesktopWallpaperWatch.sample)

        watch.tintEnabled = true
        watch.refresh()
        await watch.settled()
        let first = try #require(watch.tint)
        #expect(first.blue > first.red + 0.3, "the blue picture's color: \(first)")
        #expect(watch.sampleCount == 1 && watch.generation == 0)

        // A Space switch that shows the same picture: no sample, nothing moved.
        watch.refresh()
        await watch.settled()
        #expect(watch.sampleCount == 1 && watch.generation == 0 && watch.tint == first)

        // A new picture.
        shown = redPicture
        watch.refresh()
        await watch.settled()
        let second = try #require(watch.tint)
        #expect(second.red > second.blue + 0.3, "the red picture's color: \(second)")
        #expect(watch.sampleCount == 2 && watch.generation == 1)

        // Back to the first Space: its color without decoding again.
        shown = bluePicture
        watch.refresh()
        #expect(watch.tint == first, "a known picture's color applies at once")
        #expect(watch.sampleCount == 2 && watch.generation == 2)
    }

    /// A slow sample of a picture the desktop has already left never lands over the newer one, and
    /// the newer picture waits for it (one decode at a time) instead of starting a second.
    @Test func aStaleSampleNeverWins() async throws {
        let folder = try Self.folder()
        let slow = folder.appendingPathComponent("slow.png"), fast = folder.appendingPathComponent("fast.png")
        let (release, releasing) = AsyncStream<Void>.makeStream()
        let running = OSAllocatedUnfairLock(initialState: 0)
        var shown = slow
        let watch = DesktopWallpaperWatch(read: { Self.reading(shown, folder: folder) }, sample: { reading in
            running.withLock { $0 += 1 }
            defer { running.withLock { $0 -= 1 } }
            guard reading.picture.reportedURL == slow else { return Self.blue }
            await Task.detached { for await _ in release {} }.value
            return Self.red
        })
        watch.tintEnabled = true
        watch.refresh()
        shown = fast
        watch.refresh()
        #expect(watch.sampleCount == 1, "the newer picture waits for the decode under way")
        releasing.finish()
        await watch.settled()
        #expect(watch.sampleCount == 2)
        #expect(running.withLock { $0 } == 0)
        #expect(watch.tint == Self.blue, "the left picture's sample returned and did not land")
    }

    /// Turning the tint off while a sample runs: the sample ends, but its color is not shown.
    @Test func aSampleEndingAfterTheTintWentOffShowsNothing() async throws {
        let folder = try Self.folder()
        let (release, releasing) = AsyncStream<Void>.makeStream()
        let watch = DesktopWallpaperWatch(read: { Self.reading(folder.appendingPathComponent("blue.png"), folder: folder) }, sample: { _ in
            await Task.detached { for await _ in release {} }.value
            return Self.blue
        })
        watch.tintEnabled = true
        watch.refresh()
        watch.tintEnabled = false
        releasing.finish()
        await watch.settled()
        #expect(watch.tint == nil)
        watch.tintEnabled = true
        #expect(watch.tint == Self.blue, "its color was kept: turning the tint on again shows it at once")
        #expect(watch.sampleCount == 1)
    }

    /// A sample that ends after the app's last window went away is kept but not shown; the first
    /// read once a window shows again shows it, with no second decode.
    @Test func aSampleEndingWhileNothingShowsIsKeptNotShown() async throws {
        let folder = try Self.folder()
        let (release, releasing) = AsyncStream<Void>.makeStream()
        var hidden = false
        let shown = folder.appendingPathComponent("blue.png")
        let watch = DesktopWallpaperWatch(read: { Self.reading(shown, folder: folder) }, sample: { _ in
            await Task.detached { for await _ in release {} }.value
            return Self.blue
        }, isHidden: { hidden })
        watch.tintEnabled = true
        watch.refresh()
        hidden = true
        releasing.finish()
        await watch.settled()
        #expect(watch.tint == nil, "nothing shows: the color waits")
        hidden = false
        watch.refresh()
        #expect(watch.tint == Self.blue && watch.sampleCount == 1, "the same picture's kept color shows on the next read")
    }

    /// A picture overwritten at the same path is a new picture: it is sampled again, and the
    /// Desktop Wallpaper background reloads it. The unchanged file is never sampled twice.
    @Test func aPictureOverwrittenInPlaceIsSampledAgain() async throws {
        let folder = try Self.folder()
        let url = try Self.writePicture(Self.blue, named: "desktop.png", in: folder)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        let color = OSAllocatedUnfairLock(initialState: Self.blue)
        let watch = DesktopWallpaperWatch(read: { Self.reading(url, folder: folder) }, sample: { _ in color.withLock { $0 } })
        watch.tintEnabled = true
        watch.refresh()
        await watch.settled()
        watch.refresh()
        #expect(watch.sampleCount == 1, "the same file, unchanged, is not sampled again")

        _ = try Self.writePicture(Self.red, named: "desktop.png", in: folder)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: url.path)
        color.withLock { $0 = Self.red }
        watch.refresh()
        await watch.settled()
        #expect(watch.sampleCount == 2)
        #expect(watch.tint == Self.red)
        #expect(watch.generation == 1)
    }

    /// Hidden, the app reads nothing; the first read after it shows again catches up. With the tint
    /// off, a new picture still moves the generation (the Desktop Wallpaper art reloads) but takes
    /// no sample; turning the tint on samples the picture shown then.
    @Test func noWorkWhileHiddenAndNoSampleWhileOff() async throws {
        let folder = try Self.folder()
        var shown = folder.appendingPathComponent("blue.png"), hidden = true
        let watch = DesktopWallpaperWatch(read: { Self.reading(shown, folder: folder) }, sample: { _ in Self.blue },
                                          isHidden: { hidden })
        watch.refresh()
        #expect(watch.generation == 0 && watch.sampleCount == 0 && watch.tint == nil, "hidden: nothing read")

        hidden = false
        watch.refresh()
        shown = folder.appendingPathComponent("red.png")
        watch.refresh()
        await watch.settled()
        #expect(watch.generation == 1, "the art follows the picture with the tint off")
        #expect(watch.sampleCount == 0 && watch.tint == nil, "no sample while the tint is off")

        watch.tintEnabled = true
        await watch.settled()
        #expect(watch.sampleCount == 1 && watch.tint == Self.blue)
        watch.refresh()
        #expect(watch.sampleCount == 1, "the same picture is not sampled again")
    }

    /// A registered window material re-applies with each new color: its tint follows the picture.
    @Test func aWindowsTintFollowsThePicture() async throws {
        let folder = try Self.folder()
        let color = OSAllocatedUnfairLock(initialState: Self.blue)
        let watch = DesktopWallpaperWatch(read: { Self.reading(folder.appendingPathComponent("\(color.withLock { $0.red }).png"), folder: folder) },
                                          sample: { _ in color.withLock { $0 } })
        watch.tintEnabled = true
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 64, height: 40), images: BackdropImageStore(desktop: watch),
                                      videos: BackdropVideoPlayers())
        view.apply(WindowBackdrop(backgroundOpacity: 0.6, backgroundBlur: 0), tint: Self.darkGrey)
        let untinted = try #require(view.tintColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(abs(untinted.redComponent - untinted.blueComponent) < 0.001, "no sample yet: the theme's grey")

        watch.refresh()
        await watch.settled()
        let blue = try #require(view.tintColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(blue.blueComponent > blue.redComponent + 0.01)
        #expect(abs(blue.alphaComponent - 0.6) < 0.0001)

        color.withLock { $0 = Self.red }
        watch.refresh()
        await watch.settled()
        let red = try #require(view.tintColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(red.redComponent > red.blueComponent + 0.01)
    }

    // MARK: Fixtures

    private static func reading(_ url: URL, folder: URL) -> DesktopWallpaperWatch.Reading {
        DesktopWallpaperWatch.Reading(picture: DesktopPicture(reportedURL: url, fillColor: nil, fallbackFolder: folder), dark: false)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-tint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    private static func writePicture(_ color: WallpaperTint, named name: String, in folder: URL) throws -> URL {
        let image = try image(width: 32, height: 20) { context in
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        }
        let url = folder.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
