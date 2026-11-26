import Foundation
import Testing
@testable import CmuxMobileRealtime

/// Settings → Composer → Voice Button: Off (the default), In Send Button, Left of Field.
@MainActor
@Suite struct ComposerVoicePlacementTests {
    private func defaults() -> UserDefaults {
        let name = "ComposerVoicePlacementTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theThreeChoicesInPickerOrder() {
        #expect(ComposerVoicePlacement.allCases == [.off, .sendButton, .leading])
        #expect(ComposerVoicePlacement.allCases.map(\.title) == ["Off", "In Send Button", "Left of Field"])
    }

    @Test func offStaysTheDefault() {
        #expect(VoiceCallPreferences(defaults: defaults()).composerVoice == .off)
    }

    /// A phone that chose "Beside Send" before #56962 was reverted still has "besideSend"
    /// stored: it reads back as Off, never a blank picker.
    @Test func aStoredBesideSendReadsAsOff() {
        let store = defaults()
        store.set("besideSend", forKey: "composer.voiceButton")
        let prefs = VoiceCallPreferences(defaults: store)
        #expect(prefs.composerVoice == .off)
        prefs.composerVoice = .leading
        #expect(store.string(forKey: "composer.voiceButton") == "leading")
    }
}
