@testable import CmuxNextTerminal
import Testing

struct GhosttyBellSettingsTests {
    @Test func attentionBitNeverRequestsProcessAttentionInBackground() {
        let settings = GhosttyBellSettings(features: [.attention])

        #expect(settings.effects(appIsActive: false).isEmpty)
    }

    @Test func audioEffectsRemainAvailableWithAttentionBit() {
        let settings = GhosttyBellSettings(
            features: [.system, .audio, .attention],
            audioPath: "/tmp/bell.aiff",
            volume: 0.25
        )

        #expect(settings.effects(appIsActive: false) == [
            .systemBeep,
            .playSound(path: "/tmp/bell.aiff", volume: 0.25),
        ])
    }
}
