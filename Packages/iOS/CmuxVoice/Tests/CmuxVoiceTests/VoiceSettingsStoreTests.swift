import Foundation
import Testing
@testable import CmuxVoice

@MainActor
@Suite struct VoiceSettingsStoreTests {
    @Test func defaultsToAppleAndManualSubmit() {
        let defaults = Self.defaults()
        let store = VoiceSettingsStore(defaults: defaults)

        #expect(store.selectedEngine == .apple)
        #expect(store.voiceModeAutoSubmit == false)
        #expect(store.effectiveEngine(modelInstalled: false) == .apple)
    }

    @Test func persistsSelectedEngineAndAutoSubmit() {
        let defaults = Self.defaults()
        var store: VoiceSettingsStore? = VoiceSettingsStore(defaults: defaults)
        store?.selectedEngine = .parakeetV3
        store?.voiceModeAutoSubmit = true
        store = nil

        let reloaded = VoiceSettingsStore(defaults: defaults)
        #expect(reloaded.selectedEngine == .parakeetV3)
        #expect(reloaded.voiceModeAutoSubmit)
    }

    @Test func fallsBackToAppleWhenParakeetMissing() {
        let defaults = Self.defaults()
        let store = VoiceSettingsStore(defaults: defaults)
        store.selectedEngine = .parakeetV3

        #expect(store.effectiveEngine(modelInstalled: false) == .apple)
        #expect(store.effectiveEngine(modelInstalled: true) == .parakeetV3)
    }

    private static func defaults() -> UserDefaults {
        let suite = "CmuxVoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
