import AppKit
import CmuxNextSettings
import Testing

/// cmux#55600: on a Mac that denies cmux notifications, Settings > Sounds' play buttons and every
/// "Default" sound were silent, because "default" only ever rode a banner. The player plays every sound
/// through the app's own audio (NSSound); a banner carries "default" only while macOS sounds it.
@MainActor
struct NotificationSoundPlayerTests {
    private final class Output {
        var played: [NSSound] = []
    }

    private func player(carry: Bool) -> (NotificationSoundPlayer, Output) {
        let output = Output()
        return (NotificationSoundPlayer(bannersCarrySound: { carry }, output: { output.played.append($0) }), output)
    }

    @Test func aDefaultPreviewPlaysTheAlertSoundInTheApp() {
        let (player, output) = player(carry: true)
        player.play("default", volume: 0.4, banner: false)
        #expect(output.played.count == 1, "a preview of Default plays without any banner")
        #expect(output.played.first?.volume == 0.4)
    }

    @Test func aDefaultSoundPlaysInTheAppWhenBannersAreDenied() {
        let (player, output) = player(carry: false)
        player.play("default", volume: 1, banner: true)
        #expect(output.played.count == 1, "a banner macOS will not sound leaves Default to the app")
    }

    @Test func aBannerMacOSSoundsCarriesDefaultAlone() {
        let (player, output) = player(carry: true)
        player.play("default", volume: 1, banner: true)
        #expect(output.played.isEmpty, "the banner plays Default; the app would double it")
    }

    @Test func aNamedSoundPlaysWhateverTheBanner() {
        for carry in [true, false] {
            let (player, output) = player(carry: carry)
            player.play("Glass", volume: 1, banner: true)
            #expect(output.played.count == 1)
        }
        let (player, output) = player(carry: false)
        player.play("none", volume: 1, banner: false)
        #expect(output.played.isEmpty)
    }

    @Test func theAlertSoundIsSoundSettingsChoiceElseTink() {
        #expect(NotificationSoundPlayer.alertSoundName([:]) == NotificationSoundPlayer.fallbackAlertSound)
        #expect(NotificationSoundPlayer.alertSoundName(["com.apple.sound.beep.sound": "/System/Library/Sounds/Funk.aiff"]) == "/System/Library/Sounds/Funk.aiff")
        #expect(NotificationSoundPlayer.alertSoundName(["com.apple.sound.beep.sound": "Funk"]) == NotificationSoundPlayer.fallbackAlertSound)
    }
}
