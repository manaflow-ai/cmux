import Testing
import CmuxTerminalCore

@Suite struct GhosttyStartupAppearancePreviewProfileTests {
    @Test func loadsRealUserConfigOnlyForRealUserConfigCase() {
        #expect(GhosttyStartupAppearancePreviewProfile.realUserConfig.loadsRealUserConfig)
        #expect(!GhosttyStartupAppearancePreviewProfile.freshInstall.loadsRealUserConfig)
        #expect(!GhosttyStartupAppearancePreviewProfile.userThemePair.loadsRealUserConfig)
        #expect(!GhosttyStartupAppearancePreviewProfile.userSingleTheme.loadsRealUserConfig)
        #expect(!GhosttyStartupAppearancePreviewProfile.userExplicitColors.loadsRealUserConfig)
    }

    @Test func realUserConfigSuppliesNoSyntheticContents() {
        #expect(
            GhosttyStartupAppearancePreviewProfile.realUserConfig
                .previewConfigContents(preferredColorScheme: .dark) == nil
        )
    }

    @Test func themeProfilesEmitFrozenConfigStrings() {
        #expect(
            GhosttyStartupAppearancePreviewProfile.userThemePair
                .previewConfigContents(preferredColorScheme: .dark)
                == "theme = light:Catppuccin Latte,dark:Catppuccin Mocha"
        )
        #expect(
            GhosttyStartupAppearancePreviewProfile.userSingleTheme
                .previewConfigContents(preferredColorScheme: .light)
                == "theme = Catppuccin Mocha"
        )
        let explicit = GhosttyStartupAppearancePreviewProfile.userExplicitColors
            .previewConfigContents(preferredColorScheme: .dark)
        #expect(explicit?.contains("background = #101820") == true)
        #expect(explicit?.contains("palette = 15=#FFFFFF") == true)
    }

    @Test func allCasesAreIterableByRawValueIdentity() {
        #expect(
            GhosttyStartupAppearancePreviewProfile.allCases.map(\.id)
                == ["realUserConfig", "freshInstall", "userThemePair", "userSingleTheme", "userExplicitColors"]
        )
    }
}

#if DEBUG
@Suite struct GhosttyStartupAppearancePreviewStateTests {
    @Test func settingProfileInstallsMatchingLoaderOverride() {
        let previous = GhosttyStartupAppearancePreviewState.profile
        defer { GhosttyStartupAppearancePreviewState.profile = previous }

        GhosttyStartupAppearancePreviewState.profile = .userSingleTheme
        #expect(GhosttyStartupAppearancePreviewState.profile == .userSingleTheme)
        let override = TerminalStartupAppearancePreviewOverride.installed
        #expect(override?.loadsRealUserConfig == false)
        #expect(override?.previewConfigContents(.dark) == "theme = Catppuccin Mocha")

        GhosttyStartupAppearancePreviewState.profile = .realUserConfig
        let realOverride = TerminalStartupAppearancePreviewOverride.installed
        #expect(realOverride?.loadsRealUserConfig == true)
        #expect(realOverride?.previewConfigContents(.dark) == nil)
    }
}
#endif
