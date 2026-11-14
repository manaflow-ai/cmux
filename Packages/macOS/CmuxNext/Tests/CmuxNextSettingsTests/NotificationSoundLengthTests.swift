import CmuxNextSettings
import Foundation
import Testing

/// How long a notification sound plays (user, 2026-11-12: "customize our notification sounds and the
/// notification sound lengths as well depending on the sound file"): `notifications.sounds.maxSeconds`
/// caps every sound cmux plays itself, `notifications.sounds.lengths` sets one sound file's own
/// length, and a file shorter than its length ends on its own.
struct NotificationSoundLengthTests {
    private static func sounds(_ sounds: JSONValue) -> (NotificationSoundPreferences, [SettingsDiagnostic]) {
        let snapshot = CmuxConfigSnapshot.parse(["notifications": ["sounds": sounds]], validDensities: [], validMetrics: [])
        return (snapshot.notifications.sounds, snapshot.diagnostics)
    }

    @Test func byDefaultEverySoundPlaysToItsEnd() {
        let sounds = NotificationSoundPreferences()
        #expect(sounds.maxSeconds == 0)
        #expect(sounds.length(for: "Glass") == nil)
    }

    @Test func lengthsParseFromCmuxJSONAsTextOrNumbers() {
        let (sounds, diagnostics) = Self.sounds(["maxSeconds": 4, "lengths": ["Long Chime": "2.5", "Fanfare": 0, "Ping": 1]])
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(sounds.maxSeconds == 4)
        #expect(sounds.lengths == ["Long Chime": 2.5, "Fanfare": 0, "Ping": 1])
    }

    @Test func aLengthPast30SecondsIsClampedAndOneThatIsNotANumberIsDropped() {
        let (sounds, diagnostics) = Self.sounds(["maxSeconds": 90, "lengths": ["Ping": "long", "Pop": "45", "Glass": "1.5"]])
        #expect(sounds.maxSeconds == 30, "a cap past 30 s is clamped, as every number setting is")
        #expect(sounds.lengths == ["Pop": 30, "Glass": 1.5], "a length past 30 s is clamped; text that is not a number is dropped")
        #expect(Set(diagnostics.map(\.path)).isSuperset(of: ["notifications.sounds.maxSeconds", "notifications.sounds.lengths.Ping",
                                                              "notifications.sounds.lengths.Pop"]))
    }

    @Test func aSoundsOwnLengthWinsOverTheCapAndZeroPlaysItToItsEnd() {
        var sounds = NotificationSoundPreferences()
        sounds.maxSeconds = 4
        sounds.lengths = ["Long Chime": 2.5, "Fanfare": 0]
        #expect(sounds.length(for: "Long Chime") == 2.5)
        #expect(sounds.length(for: "Fanfare") == nil, "0 plays that file to its end, past the cap")
        #expect(sounds.length(for: "Glass") == 4, "a sound with no entry stops at the cap")
    }

    @Test func aFilePathMatchesByPathOrByItsFileName() {
        var sounds = NotificationSoundPreferences()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        sounds.lengths = ["~/Sounds/bell.m4a": 3, "Chime": 1]
        #expect(sounds.length(for: "~/Sounds/bell.m4a") == 3)
        #expect(sounds.length(for: "\(home)/Sounds/bell.m4a") == 3, "~ and the home folder name the same file")
        #expect(sounds.length(for: "/Users/me/Library/Sounds/Chime.aiff") == 1)
        #expect(sounds.length(for: "/tmp/other.wav") == nil)
    }

    @Test func aNameMatchesIgnoringCaseAndAnAudioExtension() {
        var sounds = NotificationSoundPreferences()
        sounds.lengths = ["Glass.aiff": 2, "my.sound": 4]
        #expect(sounds.length(for: "glass") == 2, "an entry written with its extension or another case still matches")
        #expect(sounds.length(for: "/System/Library/Sounds/Glass.aiff") == 2)
        #expect(sounds.length(for: "My.Sound") == 4, "a dot in a name is not an extension")
        #expect(sounds.length(for: "My") == nil)
    }

    @Test func aPathEntryWinsOverANameEntryForThatFile() {
        var sounds = NotificationSoundPreferences()
        sounds.lengths = ["Chime": 1, "/Users/me/Sounds/Chime.wav": 5]
        #expect(sounds.length(for: "/Users/me/Sounds/Chime.wav") == 5)
        #expect(sounds.length(for: "/Library/Sounds/Chime.aiff") == 1)
    }

    @Test func aSoundStopsAtItsLengthOnlyWhenItsFileIsLonger() {
        #expect(NotificationSoundPlayer.stopAfter(length: 2.5, duration: 6) == .milliseconds(2_500))
        #expect(NotificationSoundPlayer.stopAfter(length: 2.5, duration: 1.2) == nil, "a shorter file ends on its own")
        #expect(NotificationSoundPlayer.stopAfter(length: nil, duration: 6) == nil, "no length plays the whole file")
        #expect(NotificationSoundPlayer.stopAfter(length: 0, duration: 6) == nil)
    }
}
