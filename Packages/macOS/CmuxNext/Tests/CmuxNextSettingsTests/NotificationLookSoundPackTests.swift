import CmuxNextSettings
import Foundation
import Testing

/// Sound packs per look (Leo, 2026-11-19: "all of them" / "some of them maybe just as customizations
/// lol if it affects default looks"): a theme file's `"sounds"` block gives an agent that finished,
/// one that needs you and green checks their own sounds. They play only while
/// `notifications.sounds.lookPack` is on (off by default), under every mute.
struct NotificationLookSoundPackTests {
    private static let scope = NotificationSoundScope(agent: "codex", workspace: "ws_1", groups: [])

    private static func prefs(_ sounds: JSONValue = .object([:]), sound: JSONValue = "Glass",
                              pack: [NotificationSoundPreferences.LookEvent: String] = [.finished: "Hero", .needsInput: "Ping", .ciGreen: "Pop"]) -> NotificationPreferences {
        var snapshot = CmuxConfigSnapshot.parse(["notifications": ["sound": sound, "sounds": sounds]], validDensities: [], validMetrics: [])
        snapshot.notifications.sounds.lookSounds = pack
        return snapshot.notifications
    }

    @Test func thePackIsOffByDefault() {
        let prefs = Self.prefs()
        #expect(!prefs.sounds.lookPack)
        #expect(prefs.sounds.choice(for: .finished, in: Self.scope, fallback: prefs.sound)?.name == "Glass")
        #expect(prefs.lookSound(for: .ciGreen, minuteOfDay: 600) == nil)
    }

    @Test func onThePackSoundsForItsThreeMoments() {
        let prefs = Self.prefs(["lookPack": true])
        #expect(prefs.sounds.choice(for: .finished, in: Self.scope, fallback: prefs.sound)?.name == "Hero")
        #expect(prefs.sounds.choice(for: .needsInput, in: Self.scope, fallback: prefs.sound)?.name == "Ping")
        #expect(prefs.sounds.choice(for: .needsInput, in: Self.scope, fallback: prefs.sound)?.level == "look:needsInput")
        // An event the pack has no moment for keeps its sound.
        #expect(prefs.sounds.choice(for: .error, in: Self.scope, fallback: prefs.sound)?.name == "Glass")
        #expect(prefs.lookSound(for: .ciGreen, minuteOfDay: 600)?.name == "Pop")
    }

    @Test func thePersonsOwnSoundsWin() {
        let prefs = Self.prefs(["lookPack": true, "events": ["finished": "Basso"], "agents": ["codex": ["events": ["needsInput": "Funk"]]]])
        #expect(prefs.sounds.choice(for: .finished, in: Self.scope, fallback: prefs.sound)?.name == "Basso")
        #expect(prefs.sounds.choice(for: .needsInput, in: Self.scope, fallback: prefs.sound)?.name == "Funk")
    }

    @Test func everyMuteSilencesThePack() {
        // cmux muted: notifications.sound "none".
        let muted = Self.prefs(["lookPack": true], sound: "none")
        #expect(muted.sounds.choice(for: .finished, in: Self.scope, fallback: muted.sound) == nil)
        #expect(muted.lookSound(for: .ciGreen, minuteOfDay: 600) == nil)
        // A level's "none" (a muted agent kind) still mutes.
        let agentMuted = Self.prefs(["lookPack": true, "agents": ["codex": "none"]])
        #expect(agentMuted.sounds.choice(for: .finished, in: Self.scope, fallback: agentMuted.sound) == nil)
        // Volume 0.
        let silent = Self.prefs(["lookPack": true, "volume": 0])
        #expect(silent.lookSound(for: .ciGreen, minuteOfDay: 600) == nil)
        // Quiet hours.
        var quiet = Self.prefs(["lookPack": true])
        quiet.quietHours = QuietHours(start: 22 * 60, end: 7 * 60)
        #expect(quiet.lookSound(for: .ciGreen, minuteOfDay: 23 * 60) == nil)
        #expect(quiet.lookSound(for: .ciGreen, minuteOfDay: 12 * 60)?.name == "Pop")
        // The pack's own "none" for a moment.
        let packNone = Self.prefs(["lookPack": true], pack: [.ciGreen: "none"])
        #expect(packNone.lookSound(for: .ciGreen, minuteOfDay: 600) == nil)
    }

    @Test func aLookWithNoPackChangesNothing() {
        let prefs = Self.prefs(["lookPack": true], pack: [:])
        #expect(prefs.sounds.choice(for: .finished, in: Self.scope, fallback: prefs.sound)?.name == "Glass")
        #expect(prefs.lookSound(for: .ciGreen, minuteOfDay: 600) == nil)
    }

    // MARK: The theme file's "sounds"

    @Test func aThemeFileCarriesItsPackApartFromItsSettings() throws {
        let folder = URL(filePath: "/Users/me/.config/cmux/themes")
        let overlay = ThemeFileOverlay(name: "harbor", source: .success(#"""
        { "appearance.accent": "blue",
          "sounds": { "finished": "Submarine", "needsInput": "file:bell.wav", "ciGreen": "~/Sounds/ok.aiff",
                      "deploy": "Glass", "error": 3 } }
        """#), base: .object([:]), folder: folder)
        #expect(overlay.sounds[.finished] == "Submarine")
        #expect(overlay.sounds[.needsInput] == "/Users/me/.config/cmux/themes/bell.wav")
        #expect(overlay.sounds[.ciGreen] == NSString(string: "~/Sounds/ok.aiff").expandingTildeInPath)
        // The pack is no setting: only the look's settings apply.
        #expect(overlay.values.map { $0.path.joined(separator: ".") } == ["appearance.accent"])
        let refused = Set(overlay.diagnostics.map(\.path))
        #expect(refused.contains("sounds.deploy"))
        #expect(refused.contains("sounds.error"))
    }

    @Test func aPackFileStaysBesideItsThemeFile() {
        let folder = URL(filePath: "/tmp/themes")
        for bad in ["file:../secret.wav", "file:sub/x.wav", "file:notes.txt", "file:.hidden.wav"] {
            let overlay = ThemeFileOverlay(name: "t", source: .success(#"{ "sounds": { "finished": "\#(bad)" } }"#), base: .object([:]), folder: folder)
            #expect(overlay.sounds.isEmpty, "\(bad) was taken")
            #expect(overlay.diagnostics.contains { $0.path == "sounds.finished" }, "\(bad) had no diagnostic")
        }
        let notObject = ThemeFileOverlay(name: "t", source: .success(#"{ "sounds": "Glass" }"#), base: .object([:]), folder: folder)
        #expect(notObject.sounds.isEmpty)
        #expect(notObject.diagnostics.contains { $0.path == "sounds" })
    }
}
