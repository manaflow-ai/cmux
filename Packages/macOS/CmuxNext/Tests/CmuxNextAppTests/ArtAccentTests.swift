@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Art Color (`appearance.accent: "art"`, cx-t2x.5): off by default; on, a window's accent takes
/// the hue of the work it shows, and every work's hue passes the app theme's contrast contract.
@MainActor @Suite(.serialized) struct ArtAccentTests {
    static let work = BackdropArt.vanGoghStarryNight

    /// What a gallery suite leaves in the app's theme (`ThemeScope.app.store.apply`): Soft Blue, whose
    /// `cmux-accent` is #3666F0. These tests must hold whatever another suite left there (feat tip
    /// Swift suite 41190088925 and the serial run 54e4c583d660: `accentColor → #3666F0 == nil`).
    /// So each test roots its own theme tree on its own store (as CmuxNextDesignTests do): nothing another
    /// suite applies to the app's store reaches it, in a serial run or in a parallel one.
    static func withAnotherSuitesAppTheme(_ body: () throws -> Void) throws {
        let previous = ThemeScope.app.store.input
        _ = ThemeScope.app.store.apply(try AANestedGroupsGalleryTests.input("Soft Blue"))
        defer { _ = ThemeScope.app.store.apply(previous) }
        try body()
    }

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

    @Test func aWindowsAccentTakesTheHueOfTheWorkItShows() throws { try Self.withAnotherSuitesAppTheme {
        let hue = try #require(Self.work.accentHue)
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        let room = ThemeScope(level: .room, parent: app)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.pinBackdrop(.selection(.art(Self.work)))
        #expect(workspace.input.accentColor == nil)

        store.setAccentFollowsArt(true)
        #expect(workspace.input.accentColor == hue)
        #expect(workspace.tokens.accent == ThemeTokens.derive(from: workspace.input).accent)
        #expect(AppTheme.derive(from: workspace.input).failures.isEmpty)

        // Plain glass has no work, so its accent is the theme's again.
        workspace.pinBackdrop(.none)
        #expect(workspace.input.accentColor == nil)
        workspace.pinBackdrop(.selection(.art(Self.work)))
        #expect(workspace.input.accentColor == hue)

        store.setAccentFollowsArt(false)
        #expect(workspace.input.accentColor == nil)
    } }

    /// A window opened while Art Color is on draws the app's art hue on its own chrome (a top page,
    /// or a workspace of the other light or dark).
    @Test func aNewWindowTakesTheAppsArtHue() throws { try Self.withAnotherSuitesAppTheme {
        let hue = try #require(Self.work.accentHue)
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        app.setBackdropSelection(.art(Self.work))
        store.setAccentFollowsArt(true)
        let room = ThemeScope(level: .room, parent: app)
        #expect(room.input.accentColor == hue)
    } }

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
