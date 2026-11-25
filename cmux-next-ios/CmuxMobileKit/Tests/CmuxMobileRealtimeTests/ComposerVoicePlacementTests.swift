import Foundation
import Testing
@testable import CmuxMobileRealtime

/// Settings → Composer → Voice Button: Off (the default), In Send Button, Beside Send, Left
/// of Field. Leo, 2026-11-23: "should be maybe 4. side of the send button. left if always
/// showing? idk, whatever chatgpt/claude do."
@MainActor
@Suite struct ComposerVoicePlacementTests {
    private func defaults() -> UserDefaults {
        let name = "ComposerVoicePlacementTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theFourChoicesInPickerOrder() {
        #expect(ComposerVoicePlacement.allCases == [.off, .sendButton, .besideSend, .leading])
        #expect(ComposerVoicePlacement.allCases.map(\.title) == ["Off", "In Send Button", "Beside Send", "Left of Field"])
        #expect(ComposerVoicePlacement.besideSend.rawValue == "besideSend")
    }

    @Test func offStaysTheDefault() {
        #expect(VoiceCallPreferences(defaults: defaults()).composerVoice == .off)
    }

    @Test func besideSendIsReadBackFromTheSetting() {
        let store = defaults()
        store.set("besideSend", forKey: "composer.voiceButton")
        #expect(VoiceCallPreferences(defaults: store).composerVoice == .besideSend)
        let prefs = VoiceCallPreferences(defaults: store)
        prefs.composerVoice = .leading
        #expect(store.string(forKey: "composer.voiceButton") == "leading")
    }

    @Test func besideSendKeepsSendAlwaysShowing() {
        for nothing in [true, false] {
            for active in [true, false] {
                #expect(!ComposerVoicePlacement.besideSend.sendCircleIsVoice(nothingToSend: nothing, voiceActive: active))
                #expect(!ComposerVoicePlacement.leading.sendCircleIsVoice(nothingToSend: nothing, voiceActive: active))
                #expect(!ComposerVoicePlacement.off.sendCircleIsVoice(nothingToSend: nothing, voiceActive: active))
            }
        }
        #expect(ComposerVoicePlacement.besideSend.voiceBesideSend)
        #expect(ComposerVoicePlacement.allCases.filter(\.voiceBesideSend) == [.besideSend])
    }

    @Test func inSendButtonIsVoiceOnlyWithNothingToSendOrWhileOn() {
        let inSend = ComposerVoicePlacement.sendButton
        #expect(inSend.sendCircleIsVoice(nothingToSend: true, voiceActive: false))
        #expect(inSend.sendCircleIsVoice(nothingToSend: false, voiceActive: true))
        #expect(!inSend.sendCircleIsVoice(nothingToSend: false, voiceActive: false))
    }
}
