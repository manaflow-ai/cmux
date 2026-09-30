import CmuxSettings
import Testing
@testable import CmuxSettingsUI

@Suite("Voice settings rows")
struct VoiceSectionTests {
    @Test func languageRowIsDisabledOnlyForCloudEngine() {
        #expect(VoiceSection.languageRowIsEnabled(for: .onDevice))
        #expect(!VoiceSection.languageRowIsEnabled(for: .openAI))
    }
}
