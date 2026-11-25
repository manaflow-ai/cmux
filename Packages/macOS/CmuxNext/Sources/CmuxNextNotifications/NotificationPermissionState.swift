package import CmuxNextSettings
package import Foundation
import Observation

/// What macOS last said about this app's notifications (cmux#55600), observed: Settings >
/// Notifications draws its status row from it, and the notification sounds read whether a banner
/// can carry the `"default"` sound.
///
/// `authorization` is `NotificationPermission.authorization` (not_determined, denied, authorized,
/// provisional, unknown), or "automation" in a launch that never uses the system center.
@MainActor @Observable
package final class NotificationPermissionState {
    package var authorization: String
    /// macOS plays this app's banner sounds (System Settings > Notifications > Play sound); nil
    /// before the first read.
    package var sound: Bool?

    package init(authorization: String, sound: Bool? = nil) {
        self.authorization = authorization
        self.sound = sound
    }

    /// Whether a banner posted now plays its own sound (`content.sound = .default`): macOS shows it
    /// and its per-app sound switch is on. Denied, not yet asked and provisional (delivered quietly
    /// to Notification Center) banners make no sound. Unknown (before the first read) and
    /// automation (no banner at all, and no sound on a shared host) keep the banner's sound.
    package var bannersCarrySound: Bool {
        Self.bannersCarrySound(authorization: authorization, sound: sound)
    }

    package nonisolated static func bannersCarrySound(authorization: String, sound: Bool?) -> Bool {
        guard !["denied", "not_determined", "provisional"].contains(authorization) else { return false }
        return sound != false
    }

    /// Whether the person should be told: macOS refuses cmux banners, or has not asked yet.
    package var needsAttention: Bool { ["denied", "not_determined"].contains(authorization) }

    /// Settings > Notifications' status row (`notification_permission` in the host lists): null in a
    /// launch that never uses the system center.
    package var pageJSON: JSONValue {
        guard authorization != "automation" else { return .null }
        return ["authorization": .string(authorization), "sound": sound.map(JSONValue.bool) ?? .null]
    }

    /// Takes a fresh read.
    package func update(_ permission: NotificationPermission) {
        authorization = permission.authorization
        sound = permission.sound
    }
}

/// The one-time in-app notice that macOS denies cmux notifications (cmux#55600): shown once per
/// denial. Allowing notifications again re-arms it, so a later denial is told again.
package nonisolated struct NotificationDeniedNotice {
    package static let shownKey = "cmux.notifications.deniedNoticeShown"
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether to show the notice for `authorization` now; records it as shown when true.
    package func claim(for authorization: String) -> Bool {
        switch authorization {
        case "denied":
            guard !defaults.bool(forKey: Self.shownKey) else { return false }
            defaults.set(true, forKey: Self.shownKey)
            return true
        case "authorized", "provisional":
            defaults.removeObject(forKey: Self.shownKey)
            return false
        default:
            return false
        }
    }
}
