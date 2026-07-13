import Testing
@testable import CmuxSettings

@Suite("RightSidebarWidthSettings")
struct RightSidebarWidthSettingsTests {
    private let settings = RightSidebarWidthSettings()

    @Test func disabledOverrideRestoresRememberedCustomMaximumWhenEnabledAgain() {
        let restored = settings.storedMaximumWidthWhenEnabling(
            rememberedStoredValue: 1_234
        )

        #expect(restored == 1_234)
    }

    @Test func invalidRememberedMaximumFallsBackToDefaultWhenEnabled() {
        let restored = settings.storedMaximumWidthWhenEnabling(
            rememberedStoredValue: RightSidebarWidthSettings.noOverrideValue
        )

        #expect(restored == RightSidebarWidthSettings.defaultConfiguredMaximumWidth)
    }

    @Test func activeCustomMaximumWinsOverRememberedValueForEditor() {
        let editorValue = settings.editorMaximumWidth(
            activeStoredValue: 1_500,
            rememberedStoredValue: 900
        )

        #expect(editorValue == 1_500)
    }

    @Test func configuredMaximumWidthIsClampedToEditorRange() throws {
        let configured = try #require(
            settings.configuredMaximumWidth(from: 10_000)
        )

        #expect(configured == RightSidebarWidthSettings.settingsEditorMaximumWidth)
    }

    @Test func rememberedCustomMaximumIsClampedToEditorRange() {
        let restored = settings.storedMaximumWidthWhenEnabling(
            rememberedStoredValue: 10_000
        )

        #expect(restored == RightSidebarWidthSettings.settingsEditorMaximumWidth)
    }
}
