#if os(iOS)
import CmuxMobileDesign
import CoreImage
import CryptoKit
import Foundation
import GhosttyNextKit
import IOSurface
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// The phone's terminal shows the terminal theme of the Mac its session runs on, through the real
/// Ghostty surface: the terminal draws the Mac's background, follows the Mac's
/// next theme live, and keeps none of the phone's own theme settings.
@MainActor
@Suite(.serialized) struct TerminalHostThemeSurfaceTests {
    static func appearance(_ terminal: [String]) -> CmuxMobileMacAppearance {
        CmuxMobileMacAppearance(theme: .init(background: "#000000", foreground: "#ffffff",
                                             palette: (0..<8).map { _ in "#000000" }), terminal: terminal)
    }

    @MainActor final class Rig {
        let window: UIWindow
        let surface: TerminalSurfaceView

        init(macID: String, window size: CGSize = CGSize(width: 390, height: 800),
             surface frame: CGRect = CGRect(x: 0, y: 0, width: 360, height: 600)) {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
            surface = TerminalSurfaceView(frame: frame)
            surface.themeMacID = macID
            window.isHidden = false
            window.addSubview(surface)
        }

        /// Whether the presented frame's background (its bottom-right corner, away from the
        /// cursor) is `hex` within two seconds. A mirror-mode surface answers no color query (the
        /// Mac's terminal does), so the drawn frame is what shows the colors it uses. Each try feeds
        /// a carriage return so the surface draws a frame after the config change.
        func shows(_ hex: String) async -> Bool {
            guard let want = CmuxMobileTerminalTheme.rgb(hex) else { return false }
            let target = (Int(want.0 * 255), Int(want.1 * 255), Int(want.2 * 255))
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    surface.feed(Data("\r".utf8), completion: { done.resume() })
                }
                try? await Task.sleep(for: .milliseconds(40))
                if let pixel = cornerPixel(), [pixel.0 - target.0, pixel.1 - target.1, pixel.2 - target.2].allSatisfy({ abs($0) <= 8 }) {
                    return true
                }
            }
            return false
        }

        /// The frame on screen as a PNG.
        func framePNG() -> Data? { frameImage()?.pngData() }

        /// The frame on screen, its alpha kept (a see-through frame shows what is under it).
        func frameImage() -> UIImage? {
            guard let contents = surface.layer.sublayers?.first?.contents else { return nil }
            let frame = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            guard CFGetTypeID(frame) == IOSurfaceGetTypeID() else { return nil }
            let image = CIImage(ioSurface: frame)
            guard let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
            return UIImage(cgImage: cg)
        }

        /// Whether the corner pixel's alpha meets `test` within two seconds (each try feeds a
        /// carriage return so the surface draws a frame after the config change).
        func alphaBecomes(_ test: (Int) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    surface.feed(Data("\r".utf8), completion: { done.resume() })
                }
                try? await Task.sleep(for: .milliseconds(40))
                if let alpha = cornerAlpha(), test(alpha) { return true }
            }
            return false
        }

        /// The bottom-right pixel's alpha of the frame on screen (BGRA or RGBA: the fourth byte).
        func cornerAlpha() -> Int? {
            guard let contents = surface.layer.sublayers?.first?.contents else { return nil }
            let frame = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            guard CFGetTypeID(frame) == IOSurfaceGetTypeID(), IOSurfaceGetBytesPerElement(frame) == 4 else { return nil }
            let width = IOSurfaceGetWidth(frame), height = IOSurfaceGetHeight(frame)
            guard width > 4, height > 4 else { return nil }
            IOSurfaceLock(frame, .readOnly, nil)
            defer { IOSurfaceUnlock(frame, .readOnly, nil) }
            let row = IOSurfaceGetBaseAddress(frame) + (height - 3) * IOSurfaceGetBytesPerRow(frame)
            return Int((row + (width - 3) * 4).assumingMemoryBound(to: UInt8.self)[3])
        }

        /// The bottom-right pixel of the frame on screen, as 8-bit RGB (BGRA or RGBA surfaces).
        func cornerPixel() -> (Int, Int, Int)? {
            guard let contents = surface.layer.sublayers?.first?.contents else { return nil }
            let frame = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            guard CFGetTypeID(frame) == IOSurfaceGetTypeID(), IOSurfaceGetBytesPerElement(frame) == 4 else { return nil }
            let width = IOSurfaceGetWidth(frame), height = IOSurfaceGetHeight(frame)
            guard width > 4, height > 4 else { return nil }
            IOSurfaceLock(frame, .readOnly, nil)
            defer { IOSurfaceUnlock(frame, .readOnly, nil) }
            let row = IOSurfaceGetBaseAddress(frame) + (height - 3) * IOSurfaceGetBytesPerRow(frame)
            let bytes = (row + (width - 3) * 4).assumingMemoryBound(to: UInt8.self)
            // 'BGRA' is the usual Metal drawable; anything else is read as RGBA.
            let bgra = IOSurfaceGetPixelFormat(frame) == 0x4247_5241
            return bgra ? (Int(bytes[2]), Int(bytes[1]), Int(bytes[0])) : (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        }
    }

    /// Leo's NIGHTLY Mac: Catppuccin Mocha (the side-by-side on #50696). Nonisolated: `@Test(arguments:)`
    /// reads it outside the suite's main actor.
    nonisolated static let mocha = ["background = #1e1e2e", "foreground = #cdd6f4", "cursor-color = #f5e0dc",
                        "palette = 0=#45475a", "palette = 1=#f38ba8", "palette = 2=#a6e3a1", "palette = 3=#f9e2af",
                        "palette = 4=#89b4fa", "palette = 5=#f5c2e7", "palette = 6=#94e2d5", "palette = 7=#bac2de",
                        "palette = 8=#585b70", "palette = 9=#f38ba8", "palette = 10=#a6e3a1", "palette = 11=#f9e2af",
                        "palette = 12=#89b4fa", "palette = 13=#f5c2e7", "palette = 14=#94e2d5", "palette = 15=#a6adc8"]

    /// The text every picture of a theme shows: a prompt, `ls` colors, the 16 palette swatches.
    static let sample: String = {
        var text = "\u{1B}[2J\u{1B}[H~/project $ ls --color\r\n"
        text += "\u{1B}[34mSources\u{1B}[0m  \u{1B}[32mbuild.sh\u{1B}[0m  \u{1B}[35mREADME.md\u{1B}[0m  \u{1B}[31mcore.dump\u{1B}[0m\r\n\r\n"
        text += (0..<8).map { "\u{1B}[4\($0)m    " }.joined() + "\u{1B}[0m\r\n"
        text += (0..<8).map { "\u{1B}[10\($0)m    " }.joined() + "\u{1B}[0m\r\n\r\n"
        text += "\u{1B}[1mbold\u{1B}[0m \u{1B}[2mfaint\u{1B}[0m \u{1B}[33mwarning\u{1B}[0m \u{1B}[36minfo\u{1B}[0m\r\n~/project $ "
        return text
    }()

    @Test func theTerminalDrawsItsMacsColorsAndFollowsTheNextTheme() async throws {
        let macID = "mac-\(UUID().uuidString)"
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(
            ["background = #2b0b3f", "foreground = #f9e79f", "palette = 1=#ff3864"]), macID: macID)
        let rig = Rig(macID: macID)
        try #require(rig.surface.surface != nil)
        #expect(rig.surface.hostTheme?.background == "#2b0b3f")
        #expect(await rig.shows("#2b0b3f"))

        // The Mac switches theme: the open terminal takes the new one, no relaunch.
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(
            ["background = #fdf6e3", "foreground = #586e75", "palette = 1=#dc322f"]), macID: macID)
        #expect(rig.surface.hostTheme?.background == "#fdf6e3")
        #expect(rig.surface.backgroundColor == UIColor(red: 0xfd / 255, green: 0xf6 / 255, blue: 0xe3 / 255, alpha: 1))
        #expect(await rig.shows("#fdf6e3"))
    }

    /// Two Macs' themes as the phone's terminal draws them, kept as test attachments (the PR's
    /// pictures): a distinctive dark theme and a light one, with the palette and text in each.
    @Test(arguments: [
        ("aubergine-neon", ["background = #2b0b3f", "foreground = #f9e79f", "cursor-color = #ff2e97",
                            "palette = 0=#3d1458", "palette = 1=#ff3864", "palette = 2=#2de2a6", "palette = 3=#ffd319",
                            "palette = 4=#36c2ff", "palette = 5=#ff61d8", "palette = 6=#00f0e0", "palette = 7=#f2e6ff",
                            "palette = 8=#7a4fa0", "palette = 9=#ff7a9c", "palette = 10=#7dffcf", "palette = 11=#ffe873",
                            "palette = 12=#8fdcff", "palette = 13=#ffa3ec", "palette = 14=#7afff5", "palette = 15=#ffffff"]),
        // Leo's NIGHTLY Mac: Catppuccin Mocha (the side-by-side on #50696).
        ("catppuccin-mocha", Self.mocha),
        ("solarized-light", ["background = #fdf6e3", "foreground = #586e75", "cursor-color = #d33682",
                             "palette = 0=#073642", "palette = 1=#dc322f", "palette = 2=#859900", "palette = 3=#b58900",
                             "palette = 4=#268bd2", "palette = 5=#d33682", "palette = 6=#2aa198", "palette = 7=#eee8d5",
                             "palette = 8=#002b36", "palette = 9=#cb4b16", "palette = 10=#586e75", "palette = 11=#657b83",
                             "palette = 12=#839496", "palette = 13=#6c71c4", "palette = 14=#93a1a1", "palette = 15=#fdf6e3"]),
    ])
    func theMacsThemeAsDrawn(name: String, lines: [String]) async throws {
        let macID = "mac-\(name)-\(UUID().uuidString)"
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(lines), macID: macID)
        let rig = Rig(macID: macID)
        let background = try #require(CmuxMobileTerminalTheme(lines: lines)?.background)
        #expect(await rig.shows(background))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            rig.surface.feed(Data(Self.sample.utf8), completion: { done.resume() })
        }
        #expect(await rig.shows(background))
        let png = try #require(rig.framePNG())
        Attachment.record(png, named: "terminal-\(name).png")
    }

    /// Over its Mac's wallpaper the terminal is see-through, as the Mac's terminals are over its
    /// window's picture: Ghostty draws the default background transparent (the page's ground,
    /// the picture under the theme's tint, shows), and the view under it paints nothing.
    @Test func overTheMacsWallpaperTheTerminalIsSeeThrough() async throws {
        let macID = "mac-\(UUID().uuidString)"
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(["background = #1e1e2e", "foreground = #cdd6f4"]), macID: macID)
        let rig = Rig(macID: macID)
        try #require(rig.surface.surface != nil)
        #expect(await rig.shows("#1e1e2e"))
        #expect(rig.surface.isOpaque)
        #expect(rig.cornerAlpha() == 255)

        rig.surface.seeThrough = true
        #expect(!rig.surface.isOpaque)
        #expect(rig.surface.backgroundColor == .clear)
        #expect(await rig.alphaBecomes { $0 <= 8 })

        // The Mac's next theme keeps it see-through; turning it off is opaque again.
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(["background = #fdf6e3", "foreground = #586e75"]), macID: macID)
        #expect(rig.surface.backgroundColor == .clear)
        #expect(await rig.alphaBecomes { $0 <= 8 })
        rig.surface.seeThrough = false
        #expect(rig.surface.isOpaque)
        #expect(await rig.shows("#fdf6e3"))
    }

    /// The terminal over its Mac's wallpaper as the phone draws it, kept as a test attachment (the
    /// iPhone half of #51006's side-by-side, Leo 2026-11-22: "i still dont see the background image
    /// and the transparency"): the Mac's picture (the bundled van Gogh "The Starry Night", which the
    /// Mac's window shows as `appearance.background`), blurred by the Mac's regular Liquid Glass
    /// (`background_blur` -1) and under Catppuccin Mocha at the art's tint, through the phone's own
    /// steps: ``CmuxMobileMacTheme`` decodes and blurs it, ``TerminalGroundView`` paints it, and
    /// the see-through Ghostty surface draws the text over it.
    @Test func theTerminalOverTheMacsWallpaperAsDrawn() async throws {
        let picture = try #require(Self.starryNight(), "the Mac's bundled art is on the disk the simulator shares")
        let defaults = try #require(UserDefaults(suiteName: "TerminalHostThemeSurfaceTests.\(UUID().uuidString)"))
        let theme = CmuxMobileMacTheme(defaults: defaults, cache: CmuxMobileMacAppearanceCache(
            folder: FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString)", isDirectory: true)))
        let palette = Self.mocha.compactMap { $0.hasPrefix("palette = ") ? String($0.split(separator: "=").last ?? "") : nil }
        let appearance = CmuxMobileMacAppearance(
            theme: .init(background: "#1e1e2e", foreground: "#cdd6f4", palette: palette, backgroundOpacity: 0.8, backgroundBlur: -1),
            // The Mac names a picture by its SHA-256 in hex; the phone keeps only hex ids as file
            // names (`CmuxMobileMacAppearanceCache.chatWallpaperFile`), so a named id never shows.
            wallpaper: .init(id: SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined(),
                             bytes: picture.count, tintOpacity: 0.41),
            terminal: Self.mocha)
        theme.apply(appearance, chatWallpaper: picture)
        await theme.settled()
        let wallpaper = try #require(theme.wallpaper)
        #expect(wallpaper.tint == 0.41)

        // An iPhone's page: the ground fills it, the terminal sits under the status bar.
        let macID = "mac-wallpaper-\(UUID().uuidString)"
        CmuxMobileTerminalThemes.shared.apply(appearance, macID: macID)
        let rig = Rig(macID: macID, window: CGSize(width: 390, height: 844),
                      surface: CGRect(x: 0, y: 54, width: 390, height: 756))
        let background = try #require(rig.surface.hostTheme?.backgroundColor)
        let ground = TerminalGroundView(page: rig.window)
        ground.frame = rig.window.bounds
        rig.window.insertSubview(ground, belowSubview: rig.surface)
        ground.show(wallpaper, background: background)
        ground.layoutIfNeeded()
        #expect(ground.showsPicture)
        rig.surface.seeThrough = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            rig.surface.feed(Data(Self.sample.utf8), completion: { done.resume() })
        }
        #expect(await rig.alphaBecomes { $0 <= 8 })

        // The page as it shows: the ground's layers, then the terminal's frame over them.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let frame = try #require(rig.frameImage())
        let png = UIGraphicsImageRenderer(size: rig.window.bounds.size, format: format).pngData { context in
            ground.layer.render(in: context.cgContext)
            frame.draw(in: rig.surface.frame)
        }
        Attachment.record(png, named: "terminal-over-wallpaper-mocha-glass.png")
    }

    /// The Mac's bundled van Gogh, read from the Mac package in this checkout (the simulator runs on
    /// the Mac that built the tests and sees its disk).
    static func starryNight() -> Data? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // Tests/CmuxMobileTerminalTests/<file> in cmux-next-ios/CmuxMobileKit
        return try? Data(contentsOf: root.appendingPathComponent(
            "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/BackdropArt/van-gogh-starry-night.avif"))
    }

    /// The see-through config: the Mac's theme with a transparent default background.
    @Test func theSeeThroughConfigHasATransparentBackground() throws {
        _ = try CmuxMobileGhosttyApp.shared() // ghostty_init
        let base = try #require(ghostty_config_new())
        defer { ghostty_config_free(base) }
        ghostty_config_finalize(base)
        let theme = try #require(CmuxMobileTerminalTheme(lines: ["background = #1e1e2e", "foreground = #cdd6f4"]))
        let plain = try #require(CmuxMobileGhosttyApp.themedConfig(theme, fontSize: 11, base: base))
        defer { ghostty_config_free(plain) }
        let clear = try #require(CmuxMobileGhosttyApp.themedConfig(theme, fontSize: 11, seeThrough: true, base: base))
        defer { ghostty_config_free(clear) }
        #expect(double(plain, "background-opacity") == 1)
        #expect(double(clear, "background-opacity") == 0)
    }

    /// Another Mac's theme change leaves this terminal as it is.
    @Test func anotherMacsThemeDoesNotRecolorThisTerminal() async throws {
        let macID = "mac-\(UUID().uuidString)"
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(["background = #112233", "foreground = #ddeeff"]), macID: macID)
        let rig = Rig(macID: macID)
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(["background = #ffffff", "foreground = #000000"]),
                                              macID: "other-\(UUID().uuidString)")
        #expect(rig.surface.hostTheme?.background == "#112233")
        #expect(await rig.shows("#112233"))
    }

    /// The phone's own settings for theme keys never survive the Mac's theme: each key the Mac
    /// leaves unset is Ghostty's default, each it sets is the Mac's.
    @Test func noPhoneThemeSettingSurvives() throws {
        _ = try CmuxMobileGhosttyApp.shared() // ghostty_init
        let base = try #require(ghostty_config_new())
        defer { ghostty_config_free(base) }
        let phone = """
            minimum-contrast = 7
            faint-opacity = 0.9
            palette-generate = true
            palette = 200=#010203
            window-colorspace = display-p3
            font-size = 30
            """
        phone.withCString { ghostty_config_load_string(base, $0, UInt(phone.utf8.count), "phone") }
        ghostty_config_finalize(base)
        let theme = try #require(CmuxMobileTerminalTheme(lines: [
            "background = #2b0b3f", "foreground = #f9e79f", "minimum-contrast = 1.2", "palette = 1=#ff3864",
        ]))
        let themed = try #require(CmuxMobileGhosttyApp.themedConfig(theme, fontSize: 11, base: base))
        defer { ghostty_config_free(themed) }
        #expect(double(themed, "minimum-contrast") == 1.2)
        #expect(double(themed, "faint-opacity") == 0.5)
        #expect(bool(themed, "palette-generate") == false)
        #expect(text(themed, "window-colorspace") == "srgb")
        #expect(paletteEntry(themed, 200) == "#ff00d7") // xterm's default
        #expect(paletteEntry(themed, 1) == "#ff3864")
        // The surface keeps its own size (`font-size` goes with the theme, at the surface's size).
        var size: Float = 0
        #expect(ghostty_config_get(themed, &size, "font-size", UInt("font-size".utf8.count)) && size == 11)
    }

    private func double(_ config: ghostty_config_t, _ key: String) -> Double? {
        var value: Double = .nan
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    private func bool(_ config: ghostty_config_t, _ key: String) -> Bool? {
        var value = false
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    private func text(_ config: ghostty_config_t, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), let value else { return nil }
        return String(cString: value)
    }

    private func paletteEntry(_ config: ghostty_config_t, _ index: Int) -> String? {
        var palette = ghostty_config_palette_s()
        guard ghostty_config_get(config, &palette, "palette", UInt("palette".utf8.count)) else { return nil }
        return withUnsafeBytes(of: &palette.colors) { raw in
            let color = raw.bindMemory(to: ghostty_config_color_s.self)[index]
            return String(format: "#%02x%02x%02x", color.r, color.g, color.b)
        }
    }
}
#endif
