#if os(iOS)
import CmuxMobileDesign
import Foundation
import GhosttyNextKit
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// The phone's terminal shows the terminal theme of the Mac its session runs on, through the real
/// Ghostty surface: the terminal answers color queries with the Mac's colors, follows the Mac's
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
        var replies = Data()

        init(macID: String) {
            surface.themeMacID = macID
            surface.onInput = { [weak self] in self?.replies.append($0) }
            window.isHidden = false
            window.addSubview(surface)
        }

        /// What the terminal answers to `query`, once Ghostty parsed it.
        func ask(_ query: String) async -> String {
            replies.removeAll()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                surface.feed(Data(query.utf8), completion: { done.resume() })
            }
            // The reply reaches the main thread in order before the completion; one more turn
            // lets a reply written after the parse land.
            await Task.yield()
            return String(decoding: replies, as: UTF8.self)
        }
    }

    @Test func theTerminalAnswersWithItsMacsColorsAndFollowsTheNextTheme() async throws {
        let macID = "mac-\(UUID().uuidString)"
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(
            ["background = #2b0b3f", "foreground = #f9e79f", "palette = 1=#ff3864"]), macID: macID)
        let rig = Rig(macID: macID)
        try #require(rig.surface.surface != nil)
        #expect(rig.surface.hostTheme?.background == "#2b0b3f")
        #expect(await rig.ask("\u{1B}]11;?\u{1B}\\").contains("rgb:2b2b/0b0b/3f3f"))
        #expect(await rig.ask("\u{1B}]10;?\u{1B}\\").contains("rgb:f9f9/e7e7/9f9f"))
        #expect(await rig.ask("\u{1B}]4;1;?\u{1B}\\").contains("rgb:ffff/3838/6464"))

        // The Mac switches theme: the open terminal takes the new one, no relaunch.
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(
            ["background = #fdf6e3", "foreground = #586e75", "palette = 1=#dc322f"]), macID: macID)
        #expect(rig.surface.hostTheme?.background == "#fdf6e3")
        #expect(rig.surface.backgroundColor == UIColor(red: 0xfd / 255, green: 0xf6 / 255, blue: 0xe3 / 255, alpha: 1))
        #expect(await rig.ask("\u{1B}]11;?\u{1B}\\").contains("rgb:fdfd/f6f6/e3e3"))
        #expect(await rig.ask("\u{1B}]4;1;?\u{1B}\\").contains("rgb:dcdc/3232/2f2f"))
    }

    /// Another Mac's theme change leaves this terminal as it is.
    @Test func anotherMacsThemeDoesNotRecolorThisTerminal() async throws {
        let macID = "mac-\(UUID().uuidString)"
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(["background = #112233", "foreground = #ddeeff"]), macID: macID)
        let rig = Rig(macID: macID)
        CmuxMobileTerminalThemes.shared.apply(Self.appearance(["background = #ffffff", "foreground = #000000"]),
                                              macID: "other-\(UUID().uuidString)")
        #expect(rig.surface.hostTheme?.background == "#112233")
        #expect(await rig.ask("\u{1B}]11;?\u{1B}\\").contains("rgb:1111/2222/3333"))
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
