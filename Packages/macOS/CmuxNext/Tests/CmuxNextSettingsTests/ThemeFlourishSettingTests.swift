import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxTheme
import Foundation
import Testing

/// The Theme Flourishes settings (`appearance.accentGlow.*`, `.tabClose.*`, `.sidebarHeader.*`, `.paneArt.*`) and
/// `terminal.cursorStyle` / `terminal.cursorBlink` (Leo, 2026-11-17: "ok i feel like a [character] theme necessarily
/// has to have lots of [character] wallpapers among other flourishes"): every key unset is today's look; the values
/// a community theme's install writes read back as written.
@MainActor @Suite(.serialized) struct ThemeFlourishSettingTests {
    private func parse(_ root: JSONValue) -> (ThemeFlourishes, TerminalCursorSetting, [SettingsDiagnostic]) {
        var diagnostics: [SettingsDiagnostic] = []
        let flourishes = ThemeFlourishSetting.parse(root, diagnostics: &diagnostics)
        let cursor = TerminalCursorSetting.parse(root, diagnostics: &diagnostics)
        return (flourishes, cursor, diagnostics)
    }

    @Test func nothingSetIsTodaysLook() {
        let (flourishes, cursor, diagnostics) = parse(.object([:]))
        #expect(flourishes == .none)
        #expect(flourishes.accentGlow == nil && !flourishes.tabClose.isSet && flourishes.sidebarHeader == nil && flourishes.paneArt.isEmpty)
        #expect(cursor.ghosttyLines.isEmpty)
        #expect(diagnostics.isEmpty)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.flourishes == .none && snapshot.terminalCursor == TerminalCursorSetting())
    }

    @Test func aThemesValuesReadBack() throws {
        let root = try JSONC.parse("""
        {"appearance": {"accentGlow": {"dark": "#39c5bb", "radius": 24, "opacity": 0.35},
          "tabClose": {"from": "#39c5bb", "toDark": "#ff7eb9", "toLight": "#e12885", "interpolation": "srgb"},
          "sidebarHeader": {"dark": "file:/t/header/dark.webp", "light": "file:/t/header/light.webp"},
          "paneArt": {"dark": ["file:/t/pane/dark/a.webp", "file:/t/pane/dark/b.webp"], "light": ["file:/t/pane/light/a.webp"]}},
         "terminal": {"cursorStyle": "bar", "cursorBlink": "on"}}
        """)
        let (flourishes, cursor, diagnostics) = parse(root)
        #expect(diagnostics.isEmpty)
        let glow = try #require(flourishes.accentGlow)
        #expect(glow.dark == ThemeRGB(hex: 0x39C5BB) && glow.light == glow.dark, "an unset light glow takes the dark color")
        #expect(glow.radius == 24 && abs(glow.opacity - 0.35) < 0.0001)
        #expect(flourishes.tabClose.from == ThemeRGB(hex: 0x39C5BB) && flourishes.tabClose.to(dark: false) == ThemeRGB(hex: 0xE12885))
        #expect(flourishes.tabClose.space == .srgb)
        #expect(flourishes.sidebarHeader == .pair(light: .file(path: "/t/header/light.webp"), dark: .file(path: "/t/header/dark.webp")))
        // Panes take the lists in turn; the shorter light list repeats.
        #expect(flourishes.paneArt.count == 2)
        #expect(flourishes.paneArt(at: 0) == .pair(light: .file(path: "/t/pane/light/a.webp"), dark: .file(path: "/t/pane/dark/a.webp")))
        #expect(flourishes.paneArt(at: 3) == .pair(light: .file(path: "/t/pane/light/a.webp"), dark: .file(path: "/t/pane/dark/b.webp")))
        #expect(cursor.ghosttyLines == ["cursor-style = bar", "cursor-style-blink = true"])
    }

    @Test func aBadValueKeepsItsDefaultWithADiagnostic() throws {
        let root = try JSONC.parse("""
        {"appearance": {"accentGlow": {"dark": "teal"}, "tabClose": {"interpolation": "hsl"},
          "paneArt": {"dark": ["file:relative.webp"]}}, "terminal": {"cursorStyle": "wavy", "cursorBlink": true}}
        """)
        let (flourishes, cursor, diagnostics) = parse(root)
        #expect(flourishes.accentGlow == nil && flourishes.tabClose.space == .oklab && flourishes.paneArt.isEmpty)
        #expect(cursor == TerminalCursorSetting())
        let paths = Set(diagnostics.map(\.path))
        #expect(paths.isSuperset(of: ["appearance.accentGlow.dark", "appearance.tabClose.interpolation", "appearance.paneArt.dark",
                                      "terminal.cursorStyle", "terminal.cursorBlink"]), "\(paths)")
    }

    @Test func theSchemaAcceptsWhatTheReaderReads() throws {
        let art = try #require(SettingsSchema.descriptor(for: ThemeFlourishSetting.paneArtDarkPath))
        #expect(art.accepts(.array([.string("file:/t/a.webp")])) && art.accepts(.array([])))
        #expect(!art.accepts(.array([.string("file:a.webp")])) && !art.accepts(.string("file:/t/a.webp")))
        let header = try #require(SettingsSchema.descriptor(for: ThemeFlourishSetting.sidebarHeaderDarkPath))
        #expect(header.accepts(.string("file:/t/h.webp")) && !header.accepts(.string("folder:/t")))
        for path in [ThemeFlourishSetting.accentGlowDarkPath, TerminalCursorSetting.cursorStylePath] {
            let descriptor = try #require(SettingsSchema.descriptor(for: path))
            #expect(ThemeFileOverlay.isLook(descriptor), "\(path) is a theme look key")
        }
    }

    @Test func aThemeFileResolvesItsRelativePictures() throws {
        let folder = URL(fileURLWithPath: "/cfg/themes")
        let overlay = ThemeFileOverlay(name: "twin", source: .success("""
        {"appearance": {"sidebarHeader": {"dark": "file:../wallpapers/theme-a-b/header/dark.webp"},
          "paneArt": {"dark": ["file:../wallpapers/theme-a-b/pane/dark/a.webp"]}}}
        """), base: .object([:]), folder: folder)
        #expect(overlay.diagnostics.isEmpty, "\(overlay.diagnostics)")
        let values = Dictionary(uniqueKeysWithValues: overlay.values.map { ($0.path.joined(separator: "."), $0.value) })
        #expect(values["appearance.sidebarHeader.dark"] == .string("file:/cfg/wallpapers/theme-a-b/header/dark.webp"))
        #expect(values["appearance.paneArt.dark"] == .array([.string("file:/cfg/wallpapers/theme-a-b/pane/dark/a.webp")]))
    }
}
