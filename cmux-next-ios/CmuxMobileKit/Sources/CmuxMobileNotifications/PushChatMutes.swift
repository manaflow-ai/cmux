import Foundation
import UserNotifications

/// Mute Chat Notifications on this phone (the Mac's `agentChat.toggleNotificationMute`, which
/// tags the chat in the Mac's acpmux). Here it is a phone-local choice per chat, as the Feed's
/// per-workspace mute is: a muted chat's notifications arrive without a banner or a sound
/// (passive, in Notification Center only), on this phone alone. The Mac and its other phones
/// are not told.
///
/// Kept in the push keychain group, which every build has (`PushSharedPreference`), so the
/// notification service extension reads the same list as the app; a build without the group
/// keeps it in the app's defaults.
// crash-allow: its stores are thread safe (UserDefaults, and the keychain store is Sendable); the struct holds no mutable state of its own
public struct PushChatMutes: @unchecked Sendable {
    public static let account = "preference.mutedChats"
    static let defaultsKey = "cmuxMobile.push.mutedChats"

    public var keychain: (any PushSecretStore)?
    public var defaults: UserDefaults?

    public init(keychain: (any PushSecretStore)?, defaults: UserDefaults?) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// This build's store: the push keychain group, else the app's defaults.
    public static func live(bundle: Bundle = .main) -> PushChatMutes {
        let keychain = PushKeychainStore.current(bundle: bundle)
        return PushChatMutes(keychain: keychain, defaults: keychain == nil ? .standard : nil)
    }

    /// One chat: the acpmux session `session` on the Mac `mac` (its device id).
    public static func key(mac: String, session: String) -> String { "\(mac.lowercased())|\(session)" }

    public func muted() -> Set<String> {
        if let keychain {
            guard let data = try? keychain.read(Self.account),
                  let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(keys)
        }
        return Set(defaults?.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    public func isMuted(mac: String?, session: String?) -> Bool {
        guard let mac, let session, !mac.isEmpty, !session.isEmpty else { return false }
        return muted().contains(Self.key(mac: mac, session: session))
    }

    public func setMuted(_ on: Bool, mac: String, session: String) {
        var keys = muted()
        let key = Self.key(mac: mac, session: session)
        if on { keys.insert(key) } else { keys.remove(key) }
        save(keys)
    }

    /// Replaces the whole list.
    public func save(_ keys: Set<String>) {
        let list = keys.sorted()
        if let keychain {
            if list.isEmpty {
                keychain.delete(Self.account)
            } else if let data = try? JSONEncoder().encode(list) {
                try? keychain.write(data, account: Self.account)
            }
        } else {
            defaults?.set(list, forKey: Self.defaultsKey)
        }
    }

    /// Whether `userInfo` (a push's payload) belongs to a muted chat. Chief's messages and
    /// terminal notifications are never chat notifications.
    public func mutes(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = PushPayload(userInfo: userInfo), payload.kind != .chief, payload.kind != .terminal else { return false }
        return isMuted(mac: payload.mac, session: payload.sessionId)
    }

    /// The service extension's last step: a muted chat's notification is delivered quietly
    /// (no sound, passive). Nil for any other notification, which keeps its content.
    public func quieted(_ content: UNNotificationContent) -> UNNotificationContent? {
        guard mutes(content.userInfo), let out = content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        out.sound = nil
        out.interruptionLevel = .passive
        out.relevanceScore = 0
        return out
    }
}
