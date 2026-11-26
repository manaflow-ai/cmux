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

    /// The phone shows what the Mac shows behind its windows: a chosen background first, then the
    /// Ghostty `background-image`, then the desktop through a see-through window, else nothing.
    @Test func thePhoneWallpaperIsWhatTheWindowsShowBehindTheirContent() {
        let chosen = URL(fileURLWithPath: "/tmp/chosen.heic")
        let ghostty = TerminalBackgroundImage(url: URL(fileURLWithPath: "/tmp/ghostty.png"), opacity: 0.3)
        // A chosen background wins over everything, at the tint the windows lay over it.
        #expect(ThemePhone.wallpaper(selected: true, selectedPicture: chosen, selectedTint: 0.6, terminalImage: ghostty,
                                     windowSeeThrough: true, windowTint: 0.8)
                == ThemePhone.Wallpaper(source: .file(chosen), tint: 0.6))
        // One without a still (a living shader) sends none, not the desktop behind it.
        #expect(ThemePhone.wallpaper(selected: true, selectedPicture: nil, selectedTint: 0.6, terminalImage: ghostty,
                                     windowSeeThrough: true, windowTint: 0.8) == nil)
        // The Ghostty image: the background covers what the image does not, 1 - its shown opacity.
        let image = ThemePhone.wallpaper(selected: false, selectedPicture: nil, selectedTint: 0.6, terminalImage: ghostty,
                                         windowSeeThrough: false, windowTint: 1)
        #expect(image?.source == .file(ghostty.url))
        #expect(abs((image?.tint ?? 0) - 0.7) < 1e-9)
        // Desktop Wallpaper chosen in cmux: the desktop (followed as macOS rotates it), at the chosen tint.
        #expect(ThemePhone.wallpaper(selected: true, selectedDesktop: true, selectedPicture: nil, selectedTint: 0.6,
                                     terminalImage: ghostty, windowSeeThrough: true, windowTint: 0.8)
                == ThemePhone.Wallpaper(source: .desktop, tint: 0.6))
        // A see-through window: the desktop under the window's tint sheet.
        #expect(ThemePhone.wallpaper(selected: false, selectedPicture: nil, selectedTint: 0.6, terminalImage: nil,
                                     windowSeeThrough: true, windowTint: 0.8)
                == ThemePhone.Wallpaper(source: .desktop, tint: 0.8))
        // Opaque, no picture: none.
        #expect(ThemePhone.wallpaper(selected: false, selectedPicture: nil, selectedTint: 0.6, terminalImage: nil,
                                     windowSeeThrough: false, windowTint: 1) == nil)
    }

    /// The see-through input and its tint are the window's own (`WindowBackdrop` with no picture):
    /// the resolved opacity under 1 shows the desktop at that tint, 1 is opaque, Reduce Transparency
    /// is opaque whatever the opacity.
    @Test func theDesktopShowsThroughAtTheWindowsTint() {
        let translucent = WindowBackdrop(backgroundOpacity: 0.75, backgroundBlur: 0)
        #expect(!translucent.isOpaque)
        #expect(ThemePhone.wallpaper(selected: false, selectedPicture: nil, selectedTint: 0.6, terminalImage: nil,
                                     windowSeeThrough: !translucent.isOpaque, windowTint: translucent.tintOpacity)
                == ThemePhone.Wallpaper(source: .desktop, tint: 0.75))
        #expect(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 0).isOpaque)
        #expect(WindowBackdrop(backgroundOpacity: 0.75, backgroundBlur: 0, reduceTransparency: true).isOpaque)
    }

    /// `background_blur` is the window's resolved material in Ghostty's encoding.
    @Test func theBlurIsTheWindowsResolvedMaterial() {
        #expect(ThemePhone.blur(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 0)) == 0)
        #expect(ThemePhone.blur(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 0)) == 0)
        #expect(ThemePhone.blur(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 12)) == 12)
        #expect(ThemePhone.blur(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: -1, liquidGlass: true)) == -1)
        #expect(ThemePhone.blur(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: -2, liquidGlass: true)) == -2)
        // Glass this Mac cannot draw frosts at Ghostty.app's radius.
        #expect(ThemePhone.blur(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: -2, liquidGlass: false))
                == WindowBackdrop.glassFallbackBlurRadius)
    }

    /// A Ghostty `background-image`'s shown opacity stays in 0...1 (a raised
    /// `background-image-opacity` over a carrier background can pass 1 on its own).
    @Test func theGhosttyImageOpacityStaysAnAlpha() {
        #expect(TerminalBackgroundImage(url: URL(fileURLWithPath: "/tmp/a.png"), opacity: 3).opacity == 1)
        #expect(TerminalBackgroundImage(url: URL(fileURLWithPath: "/tmp/a.png"), opacity: -1).opacity == 0)
        #expect(TerminalBackgroundImage(url: URL(fileURLWithPath: "/tmp/a.png"), opacity: 0.4).opacity == 0.4)
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
