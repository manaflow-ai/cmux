import Testing
@testable import CmuxSettings

@Suite("SessionContentWidthSettings")
struct SessionContentWidthSettingsTests {
    private let settings = SessionContentWidthSettings()

    @Test func catalogDefaultsToNoMaximumWidth() {
        let defaultValue = TerminalCatalogSection().sessionContentMaxWidth.defaultValue

        #expect(defaultValue == SessionContentWidthSettings.noMaximumWidth)
        #expect(settings.configuredMaximumWidth(from: defaultValue) == nil)
    }

    @Test func disabledSentinelResolvesToNoMaximumWidth() {
        #expect(settings.configuredMaximumWidth(from: SessionContentWidthSettings.noMaximumWidth) == nil)
    }

    @Test func configuredWidthEnforcesMinimumAndRoundsWithoutUpperBound() {
        #expect(settings.configuredMaximumWidth(from: 1111) == 1120)
        #expect(settings.configuredMaximumWidth(from: 10) == SessionContentWidthSettings.minimumWidth)
        #expect(settings.configuredMaximumWidth(from: 10_000) == 10_000)
        #expect(settings.configuredMaximumWidth(from: .greatestFiniteMagnitude)?.isFinite == true)
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
