import Foundation
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite("MobileVoiceSettings")
struct MobileVoiceSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "MobileVoiceSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("defaults without stored values")
    func defaults() {
        let settings = MobileVoiceSettings(
            defaults: makeDefaults(),
            apiKeyStore: MobileVoiceInMemoryAPIKeyStore()
        )
        #expect(settings.voiceModeEnabled)
        #expect(settings.voiceName == "marin")
        #expect(settings.speakAgentReplies)
        #expect(!settings.speakCodeBlocks)
        #expect(!settings.speakToolActivity)
        #expect(settings.spokenReplyLength == .medium)
        #expect(settings.userOpenAIAPIKey.isEmpty)
        #expect(!settings.orchestratorBypassPermissions)
    }

    @Test("mutations persist across instances")
    func persistence() {
        let defaults = makeDefaults()
        let keyStore = MobileVoiceInMemoryAPIKeyStore()
        let settings = MobileVoiceSettings(defaults: defaults, apiKeyStore: keyStore)
        settings.voiceModeEnabled = false
        settings.voiceName = "cinder"
        settings.speakCodeBlocks = true
        settings.spokenReplyLength = .long
        settings.orchestratorBypassPermissions = true
        settings.userOpenAIAPIKey = " sk-test-123 "

        let reloaded = MobileVoiceSettings(defaults: defaults, apiKeyStore: keyStore)
        #expect(!reloaded.voiceModeEnabled)
        #expect(reloaded.voiceName == "cinder")
        #expect(reloaded.speakCodeBlocks)
        #expect(reloaded.spokenReplyLength == .long)
        #expect(reloaded.orchestratorBypassPermissions)
        // The key round-trips trimmed, through the key store only.
        #expect(reloaded.userOpenAIAPIKey == "sk-test-123")
        #expect(keyStore.load() == "sk-test-123")
    }

    @Test("unknown persisted voice falls back to the default")
    func unknownVoiceFallsBack() {
        let defaults = makeDefaults()
        defaults.set("retired-voice", forKey: "cmux.mobile.voice.voiceName")
        let settings = MobileVoiceSettings(
            defaults: defaults,
            apiKeyStore: MobileVoiceInMemoryAPIKeyStore()
        )
        #expect(settings.voiceName == "marin")
    }

    @Test("clearing the key removes it from the store")
    func clearingKey() {
        let keyStore = MobileVoiceInMemoryAPIKeyStore(key: "sk-old")
        let settings = MobileVoiceSettings(defaults: makeDefaults(), apiKeyStore: keyStore)
        #expect(settings.userOpenAIAPIKey == "sk-old")
        settings.userOpenAIAPIKey = "   "
        #expect(settings.userOpenAIAPIKey.isEmpty)
        #expect(keyStore.load() == nil)
    }

    @Test("filter options mirror the settings")
    func filterOptions() {
        let settings = MobileVoiceSettings(
            defaults: makeDefaults(),
            apiKeyStore: MobileVoiceInMemoryAPIKeyStore()
        )
        settings.speakCodeBlocks = true
        settings.spokenReplyLength = .short
        let options = settings.speakableTextOptions
        #expect(options.speakCodeBlocks)
        #expect(options.maximumCharacters == MobileVoiceSettings.SpokenReplyLength.short.maximumCharacters)
    }
}
