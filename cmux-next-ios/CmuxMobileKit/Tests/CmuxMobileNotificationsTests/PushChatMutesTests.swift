import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// Mute Chat Notifications on this phone: the app and the service extension read one list, and a
/// muted chat's push arrives quietly while others keep their sound.
@Suite struct PushChatMutesTests {
    @Test func aMutedChatsPushArrivesQuietly() throws {
        let mutes = PushChatMutes(keychain: PushMemoryStore(), defaults: nil)
        mutes.setMuted(true, mac: "MAC-1", session: "sess-1")
        #expect(mutes.muted() == ["mac-1|sess-1"])

        let muted = UNMutableNotificationContent()
        muted.sound = .default
        muted.userInfo = PushPayload(mac: "mac-1", kind: .completed, sessionId: "sess-1").userInfo
        let quiet = try #require(mutes.quieted(muted))
        #expect(quiet.sound == nil)
        #expect(quiet.interruptionLevel == .passive)

        // Another chat, Chief and a terminal notification keep their alert.
        for payload in [PushPayload(mac: "mac-1", kind: .completed, sessionId: "sess-2"),
                        PushPayload(mac: "mac-1", kind: .chief, sessionId: "sess-1"),
                        PushPayload(mac: "mac-1", kind: .terminal, sessionId: "sess-1")] {
            let other = UNMutableNotificationContent()
            other.userInfo = payload.userInfo
            #expect(mutes.quieted(other) == nil)
        }

        mutes.setMuted(false, mac: "mac-1", session: "sess-1")
        #expect(mutes.muted().isEmpty)
        #expect(mutes.quieted(muted) == nil)
    }

    @Test func aBuildWithoutTheKeychainGroupKeepsItInDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "PushChatMutesTests-\(UUID().uuidString)"))
        let mutes = PushChatMutes(keychain: nil, defaults: defaults)
        mutes.setMuted(true, mac: "m", session: "s")
        #expect(PushChatMutes(keychain: nil, defaults: defaults).isMuted(mac: "M", session: "s"))
    }
}
