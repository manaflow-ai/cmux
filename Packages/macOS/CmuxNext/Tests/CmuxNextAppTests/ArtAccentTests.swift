@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Art Color (`appearance.accent: "art"`, cx-t2x.5): off by default; on, a window's accent takes
/// the hue of the work it shows, and every work's hue passes the app theme's contrast contract.
@MainActor @Suite(.serialized) struct ArtAccentTests {
    static let work = BackdropArt.vanGoghStarryNight

    @Test func artColorIsAChoiceOfTheAccentAndOffByDefault() {
        #expect(!AccentSetting.followsArt(.object([:])))
        #expect(!AccentSetting.followsArt(["appearance": ["accent": "theme"]]))
        let root: JSONValue = ["appearance": ["accent": "art"]]
        #expect(AccentSetting.followsArt(root))
        // The tokens' own accent stays neutral; the art's hue comes in per scope.
        let (accent, diagnostic) = AccentSetting().parse(root)
        #expect(accent == .neutral)
        #expect(diagnostic == nil)
        #expect(SettingsSchema.descriptor(for: AccentSetting().configPath)?.accepts("art") == true)
    }

    @Test func aWindowsAccentTakesTheHueOfTheWorkItShows() throws {
        let hue = try #require(Self.work.accentHue)
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.pinBackdrop(.selection(.art(Self.work)))
        #expect(workspace.input.accentColor == nil)

        ThemeScope.app.store.setAccentFollowsArt(true)
        defer { ThemeScope.app.store.setAccentFollowsArt(false) }
        #expect(workspace.input.accentColor == hue)
        #expect(workspace.tokens.accent == ThemeTokens.derive(from: workspace.input).accent)
        #expect(AppTheme.derive(from: workspace.input).failures.isEmpty)

        // Plain glass has no work, so its accent is the theme's again.
        workspace.pinBackdrop(.none)
        #expect(workspace.input.accentColor == nil)
        workspace.pinBackdrop(.selection(.art(Self.work)))
        #expect(workspace.input.accentColor == hue)

        ThemeScope.app.store.setAccentFollowsArt(false)
        #expect(workspace.input.accentColor == nil)
    }

    /// A window opened while Art Color is on draws the app's art hue on its own chrome (a top page,
    /// or a workspace of the other light or dark).
    @Test func aNewWindowTakesTheAppsArtHue() throws {
        let hue = try #require(Self.work.accentHue)
        ThemeScope.app.setBackdropSelection(.art(Self.work))
        defer { ThemeScope.app.setBackdropSelection(nil) }
        ThemeScope.app.store.setAccentFollowsArt(true)
        defer { ThemeScope.app.store.setAccentFollowsArt(false) }
        let room = ThemeScope(level: .room)
        #expect(room.input.accentColor == hue)
    }

    @Test func everyWorksArtColorPassesTheContrastContractOnDarkAndLight() {
        var dark = ThemeInput.ghosttyDefault
        dark.background = ThemeRGB(hex: 0x1D1F21)
        dark.foreground = ThemeRGB(hex: 0xC5C8C6)
        var light = dark
        light.background = ThemeRGB(hex: 0xFAFAFA)
        light.foreground = ThemeRGB(hex: 0x1D1F21)
        let hues = BackdropArt.allCases.compactMap(\.accentHue)
        // Most works are colorful enough to lend a hue; the rest keep the neutral accent.
        #expect(hues.count * 2 > BackdropArt.allCases.count)
        for hue in hues {
            for var input in [dark, light] {
                input.accentColor = hue
                #expect(AppTheme.derive(from: input).failures.isEmpty, "\(hue) on \(input.background)")
            }
        }
    }
}
