import CmuxNextSettings
import Foundation
import Testing

/// The sound gate: ten agents finishing at once sound once, an agent asking still sounds, a seen
/// pane sounds only under `when = always`, and the chosen volume reaches the player.
@MainActor
struct NotificationSoundGateTests {
    @MainActor private final class Recorder: NotificationSoundPlaying {
        var played: [(name: String, volume: Double, banner: Bool)] = []
        func play(_ name: String, volume: Double, banner: Bool) { played.append((name, volume, banner)) }
    }

    private final class Clock {
        var now = ContinuousClock.now
    }

    private static func decision(_ event: NotificationSoundEvent, sound: String? = "Glass", volume: Double = 1) -> NotificationPolicy.Decision {
        var decision = NotificationPolicy.Decision()
        decision.sound = sound
        decision.soundEvent = event
        decision.soundVolume = volume
        return decision
    }

    @Test func aBurstOfFinishesSoundsOnceAndAnAskStillSounds() {
        let recorder = Recorder(), clock = Clock()
        let gate = NotificationSoundGate(player: recorder, now: { clock.now })
        for _ in 0..<10 {
            gate.play(Self.decision(.finished), cooldownSeconds: 1.5, banner: false)
            clock.now += .milliseconds(50)
        }
        gate.play(Self.decision(.needsInput, sound: "Ping"), cooldownSeconds: 1.5, banner: false)
        #expect(recorder.played.map(\.name) == ["Glass", "Ping"])
        clock.now += .seconds(2)
        gate.play(Self.decision(.finished), cooldownSeconds: 1.5, banner: false)
        #expect(recorder.played.count == 3, "after the cooldown a finish sounds again")
    }

    @Test func aHeldSoundSilencesItsBannerToo() {
        let clock = Clock()
        let gate = NotificationSoundGate(player: Recorder(), now: { clock.now })
        var first = Self.decision(.finished), second = Self.decision(.finished)
        let firstAdmitted = gate.admit(&first, cooldownSeconds: 1.5)
        let secondAdmitted = gate.admit(&second, cooldownSeconds: 1.5)
        #expect(firstAdmitted)
        #expect(!secondAdmitted)
        #expect(first.sound == "Glass")
        #expect(second.sound == nil, "the banner posted for a held sound carries none")
    }

    @Test func theVolumeReachesThePlayer() {
        let recorder = Recorder()
        let gate = NotificationSoundGate(player: recorder)
        gate.play(Self.decision(.error, sound: "Basso", volume: 0.3), cooldownSeconds: 0, banner: false)
        #expect(recorder.played.first?.volume == 0.3)
    }

    @Test func aSeenPaneSoundsOnlyUnderAlways() {
        let recorder = Recorder()
        let gate = NotificationSoundGate(player: recorder)
        var sounds = NotificationSoundPreferences()
        sounds.cooldownSeconds = 0
        gate.playSeen(Self.decision(.finished), sounds: sounds)
        #expect(recorder.played.isEmpty)
        sounds.when = .always
        gate.playSeen(Self.decision(.finished), sounds: sounds)
        #expect(recorder.played.map(\.name) == ["Glass"])
    }
}
