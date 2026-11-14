import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Leo 2026-11-07: "perhaps, like, have hints of your background wallpaper, or some other selection of the background
/// wallpaper as possible for the thing. You know, like a pictorial group." The pictorial palette draws each group from
/// the desktop picture at the height of its place: the picture is sampled in bands, top first.
@MainActor @Suite struct GroupPictorialPaletteTests {
    /// A picture red in its top half and blue in its bottom half (CoreGraphics' y runs up).
    static func redOverBlue() throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.15, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 16, width: 32, height: 16))
        return try #require(context.makeImage())
    }

    @Test func bandsRunTopToBottom() throws {
        let bands = WallpaperTint.bands(of: try Self.redOverBlue(), count: 4)
        #expect(bands.count == 4)
        let top = try #require(bands.first), bottom = try #require(bands.last)
        #expect(top.red > 0.7 && top.blue < 0.3, "the top band is the picture's top (red): \(top)")
        #expect(bottom.blue > 0.7 && bottom.red < 0.3, "the bottom band is the picture's bottom (blue): \(bottom)")
    }

    /// A group's color keeps its band's hue, at the lightness group colors draw at; a grey band stays grey.
    @Test func aGroupTakesItsBandsHue() {
        let bands = [WallpaperTint(red: 0.5, green: 0.08, blue: 0.06), WallpaperTint(red: 0.3, green: 0.3, blue: 0.3)]
        let top = GroupColor.pictorialRGB(bands, at: 0).oklch
        let band = ThemeRGB(red: 0.5, green: 0.08, blue: 0.06).oklch
        #expect(abs(top.hue - band.hue) < 4, "hue \(top.hue), the band's \(band.hue)")
        #expect(abs(top.lightness - 0.72) < 0.02, "lifted to the group colors' lightness: \(top.lightness)")
        #expect(GroupColor.pictorialRGB(bands, at: 1).oklch.chroma < 0.02, "a grey band stays grey")
    }

    /// The pictorial palette has the picture sampled for the groups without leaning the windows' tint toward it:
    /// `samplesForGroups` samples while `tintEnabled` (the window tint) stays off.
    @Test func groupsHaveThePictureSampledWithoutTheWindowTint() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pictorial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = DesktopPicture(reportedURL: folder.appendingPathComponent("p.png"), fillColor: nil, fallbackFolder: folder)
        var sampled = WallpaperTint(red: 0.2, green: 0.4, blue: 0.7)
        sampled.bands = [WallpaperTint(red: 0.8, green: 0.2, blue: 0.1)]
        let color = sampled
        let watch = DesktopWallpaperWatch(read: { DesktopWallpaperWatch.Reading(picture: picture, dark: false) }, sample: { _ in color })
        defer { DesignSettings.shared.groupWallpaperTint = nil }
        await watch.refreshed()
        #expect(watch.tint == nil, "nothing asked for the picture yet")
        watch.samplesForGroups = true
        await watch.settled()
        #expect(watch.tint == color && watch.tint?.bands.count == 1)
        #expect(DesignSettings.shared.groupWallpaperTint?.bands == color.bands, "the bands reach the groups")
        #expect(!watch.tintEnabled, "the windows' tint stays off")
    }

    /// The pictorial marble is the picture's bands; a token drawn on its own takes the wallpaper palette's color.
    @Test func theMarbleAndALoneTokenFollowThePicture() {
        let tokens = ThemeScope.app.tokens
        var wallpaper = WallpaperTint(red: 0.2, green: 0.35, blue: 0.6)
        wallpaper.bands = (0 ..< 16).map { WallpaperTint(red: Double($0) / 15, green: 0.3, blue: 1 - Double($0) / 15) }
        #expect(GroupColor.marble(.pictorial, tokens: tokens, wallpaper: wallpaper).count == 8)
        #expect(GroupColor.red.paletteRGB(.pictorial, tokens: tokens, wallpaper: wallpaper)
            == GroupColor.red.paletteRGB(.wallpaper, tokens: tokens, wallpaper: wallpaper))
    }
}
