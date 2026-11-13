#if os(iOS)
import CmuxMobileDesign
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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))

        init(macID: String) {
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
