import Foundation
import Testing
@testable import CmuxNotifications

@Suite("Notification policy effects patch")
struct NotificationPolicyEffectsPatchTests {
    /// The plain defaults keep every effect on, and the mute constructor turns every effect off.
    @Test func defaultsAreOnAndAllSuppressedIsOff() {
        let defaults = NotificationPolicyEffects()
        for flag in [defaults.record, defaults.markUnread, defaults.reorderWorkspace, defaults.desktop, defaults.sound, defaults.command, defaults.paneFlash] {
            #expect(flag)
        }
        let suppressed = NotificationPolicyEffects.allSuppressed
        for flag in [suppressed.record, suppressed.markUnread, suppressed.reorderWorkspace, suppressed.desktop, suppressed.sound, suppressed.command, suppressed.paneFlash] {
            #expect(!flag)
        }
    }

    /// An absent or empty patch resolves to the defaults.
    @Test func absentFieldsKeepTheDefaults() {
        #expect(NotificationPolicyEffects(applying: nil) == NotificationPolicyEffects())
        #expect(NotificationPolicyEffects(applying: NotificationPolicyEffectsPatch()) == NotificationPolicyEffects())
        #expect(NotificationPolicyEffectsPatch().merged(into: .allSuppressed) == .allSuppressed)
    }

    /// A single boolean override changes only its own effect.
    @Test func booleanOverridesChangeOnlyTheirField() {
        let effects = NotificationPolicyEffects(applying: NotificationPolicyEffectsPatch(desktop: false))
        #expect(!effects.desktop)
        #expect(effects.record)
        #expect(effects.markUnread)
        #expect(effects.reorderWorkspace)
        #expect(effects.sound)
        #expect(effects.command)
        #expect(effects.paneFlash)
        #expect(effects == NotificationPolicyEffects(desktop: false))
    }

    /// Merging applies present fields over any base and leaves absent fields as the base had them.
    @Test func mergePreservesTheBaseForAbsentFields() {
        let base = NotificationPolicyEffects(desktop: false, sound: false)
        let merged = NotificationPolicyEffectsPatch(sound: true, paneFlash: false).merged(into: base)
        #expect(merged == NotificationPolicyEffects(desktop: false, sound: true, paneFlash: false))
        let restored = NotificationPolicyEffectsPatch(desktop: true).merged(into: base)
        #expect(restored == NotificationPolicyEffects(sound: false))
    }

    /// A patch decodes from the hook wire shape and encodes only its present fields.
    @Test func patchRoundTripsTheHookWireShape() throws {
        let decoded = try JSONDecoder().decode(NotificationPolicyEffectsPatch.self, from: Data(#"{"desktop":false}"#.utf8))
        #expect(decoded == NotificationPolicyEffectsPatch(desktop: false))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(NotificationPolicyEffectsPatch(desktop: false, sound: true))
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"desktop":false,"sound":true}"#)
    }

    /// Effects decode with absent keys on, and a full round trip preserves every field.
    @Test func effectsDecodeAbsentKeysAsOn() throws {
        let empty = try JSONDecoder().decode(NotificationPolicyEffects.self, from: Data("{}".utf8))
        #expect(empty == NotificationPolicyEffects())
        let partial = try JSONDecoder().decode(NotificationPolicyEffects.self, from: Data(#"{"desktop":false,"command":false}"#.utf8))
        #expect(partial == NotificationPolicyEffects(desktop: false, command: false))
        let roundTrip = try JSONDecoder().decode(NotificationPolicyEffects.self, from: JSONEncoder().encode(NotificationPolicyEffects.allSuppressed))
        #expect(roundTrip == .allSuppressed)
    }
}
