import CmuxNextDesign
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// ask-87d30da8e5: the iPhone gets the colors this Mac's chrome derives from, so its own
/// `ThemeTokens.derive` lands on the same palette.
@MainActor
@Suite struct ThemePhoneTests {
    @Test func thePhoneGetsTheChromeInputAsHex() {
        var input = ThemeInput.ghosttyDefault
        input.accent = .blue
        input.selectionBackground = ThemeRGB(hex: 0x585B70)
        let tokens = ThemeTokens.derive(from: input)
        let sent = ThemePhone.appearance(input: input, tokens: tokens, accentFollowsArt: false, tint: 0.6)
        #expect(sent.background == "#282c34")
        #expect(sent.foreground == "#ffffff")
        #expect(sent.palette.count == 16)
        #expect(sent.palette.first == "#1d1f21")
        #expect(sent.selectionBackground == "#585b70")
        #expect(sent.cursor == nil)
        #expect(sent.accent == "blue")
        #expect(sent.accentColor == nil)
        #expect(sent.wallpaperTintOpacity == 0.6)
    }

    /// Art Color: the accent the windows show (the art's hue) goes as the theme's own accent.
    @Test func artColorSendsTheShownAccent() {
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        let sent = ThemePhone.appearance(input: .ghosttyDefault, tokens: tokens, accentFollowsArt: true, tint: 0)
        #expect(sent.accent == "art")
        #expect(sent.accentColor == ThemePhone.hex(tokens.accent))
    }

    /// ask-a6804c4472 (Leo: "i still dont see the background image and the transparency"): the
    /// phone gets the picture and tint the window paints. A see-through window with no picked
    /// picture shows the desktop through it, so the phone gets the desktop picture; a Ghostty
    /// `background-opacity` under 1 is the tint over a picked picture too (it used to send the
    /// theme's wallpaper tint); an opaque window sends no picture.
    @Test func thePhoneGetsThePictureAndTintTheWindowPaints() {
        var input = ThemeInput.ghosttyDefault
        input.backgroundOpacity = 0.7
        let seeThrough = ThemeTokens.derive(from: input)
        let opaque = ThemeTokens.derive(from: .ghosttyDefault)
        let art = BackdropSelection.file(path: "/tmp/wallpaper.png")

        let desktop = ThemePhone.backdrop(selection: nil, window: WindowBackdrop(seeThrough))
        #expect(desktop.source == .desktop)
        #expect(abs(desktop.tint - 0.7) < 0.000_1)

        let none = ThemePhone.backdrop(selection: nil, window: WindowBackdrop(opaque))
        #expect(none.source == nil)
        #expect(none.tint == 1)

        let picked = ThemePhone.backdrop(selection: art, window: WindowBackdrop(seeThrough, selection: art))
        #expect(picked.source == art)
        #expect(abs(picked.tint - 0.7) < 0.000_1)

        // An opaque theme over a picture: the theme's own tint over it, as the window lays it.
        let themed = ThemePhone.backdrop(selection: art, window: WindowBackdrop(opaque, selection: art))
        #expect(themed.source == art)
        #expect(abs(themed.tint - WindowBackdrop(opaque, selection: art).tintOpacity) < 0.000_1)
        #expect(themed.tint < 1)

        // The window Opacity the person set wins over the theme's tint; Reduce Transparency hides everything.
        let set = ThemePhone.backdrop(selection: art, window: WindowBackdrop(opaque, selection: art, tintOpacity: 0.4))
        #expect(abs(set.tint - 0.4) < 0.000_1)
        let reduced = ThemePhone.backdrop(selection: art, window: WindowBackdrop(seeThrough, reduceTransparency: true, selection: art))
        #expect(reduced.source == nil)
        #expect(reduced.tint == 1)
    }

    /// The phone-copy folder keeps only the current picture's copy: a new wallpaper's copy replaces
    /// the earlier one instead of piling up.
    @Test func thePhoneCopyFolderKeepsOnlyTheCurrentPicture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThemePhoneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("phone-wallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = try Self.png(at: root.appendingPathComponent("first.png"), gray: 0.2)
        let second = try Self.png(at: root.appendingPathComponent("second.png"), gray: 0.8)

        let one = try #require(BackdropImageStore.phoneCopy(of: first, dark: true, in: folder))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [one.lastPathComponent])
        let two = try #require(BackdropImageStore.phoneCopy(of: second, dark: true, in: folder))
        #expect(two != one)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [two.lastPathComponent])
        // The same picture again reuses its copy and still leaves only it.
        #expect(BackdropImageStore.phoneCopy(of: second, dark: true, in: folder) == two)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [two.lastPathComponent])
    }

    /// A 64 by 64 gray PNG at `url`.
    static func png(at url: URL, gray: CGFloat) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
