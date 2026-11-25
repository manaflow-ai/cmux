package import CmuxNextSettings
import Foundation
import Observation

/// What macOS last said about this app's notifications (cmux#55600), observed: Settings >
/// Notifications draws its status row from it, and the notification sounds play only while it allows them.
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

    /// Whether cmux plays notification sounds now (cmux#55600): only while macOS allows cmux notifications with
    /// sound (System Settings > Notifications > Allow Notifications and Play sound). Denied, not yet asked and
    /// provisional (delivered quietly) stay silent. Unknown (before the first read) and automation (no system
    /// center) keep sounds on.
    package var allowsSounds: Bool {
        Self.allowsSounds(authorization: authorization, sound: sound)
    }

    package nonisolated static func allowsSounds(authorization: String, sound: Bool?) -> Bool {
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
