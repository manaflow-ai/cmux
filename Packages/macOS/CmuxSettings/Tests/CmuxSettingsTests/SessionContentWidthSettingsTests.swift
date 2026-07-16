import Testing
@testable import CmuxSettings

@Suite("SessionContentWidthSettings")
struct SessionContentWidthSettingsTests {
    private let settings = SessionContentWidthSettings()

    @Test func disabledSentinelResolvesToNoMaximumWidth() {
        #expect(settings.configuredMaximumWidth(from: SessionContentWidthSettings.noMaximumWidth) == nil)
    }

    @Test func configuredWidthClampsAndRoundsToEditorStep() {
        #expect(settings.configuredMaximumWidth(from: 1111) == 1120)
        #expect(settings.configuredMaximumWidth(from: 10) == SessionContentWidthSettings.minimumWidth)
        #expect(settings.configuredMaximumWidth(from: 9999) == SessionContentWidthSettings.maximumWidth)
    }

    @Test func editorUsesRememberedWidthWhileDisabled() {
        let width = settings.editorMaximumWidth(
            activeStoredValue: SessionContentWidthSettings.noMaximumWidth,
            rememberedStoredValue: 1180
        )
        #expect(width == 1180)
    }

    @Test func nonFiniteRememberedWidthUsesDefault() {
        let width = settings.editorMaximumWidth(
            activeStoredValue: SessionContentWidthSettings.noMaximumWidth,
            rememberedStoredValue: .infinity
        )
        #expect(width == SessionContentWidthSettings.defaultConfiguredMaximumWidth)
    }

    @Test(arguments: SessionContentAlignment.allCases)
    func alignmentRoundTripsThroughSettingsStorage(alignment: SessionContentAlignment) {
        #expect(SessionContentAlignment.decodeFromUserDefaults(alignment.encodeForUserDefaults()) == alignment)
        #expect(SessionContentAlignment.decodeFromJSON(alignment.encodeForJSON()) == alignment)
    }
}
