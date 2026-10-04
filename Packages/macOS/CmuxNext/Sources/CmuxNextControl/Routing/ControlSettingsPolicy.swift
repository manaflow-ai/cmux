public import CmuxNextSettings
import Foundation

/// Who a socket settings write acts for, and its refusals (SECURITY, agent_settable). Its own
/// type, not a `ControlRouter` member (that type's line budget is full).
enum ControlSettingsPolicy {
    /// `call`'s writer: the request's checked `origin` (`user` only in process), else `cli`. A
    /// socket caller is never the user; `confirm: true` asks the person on a native sheet.
    static func writer(_ call: ControlCall) throws -> SettingWriter {
        let origin = try ControlOrigin().validated(call.params["origin"], connection: call.connection) ?? "cli"
        return origin == "user" ? .user : .caller(origin)
    }

    /// The refusal of a user-only key, with the two ways a person can change it.
    static func userOnly(_ key: String) -> ControlError {
        ControlError(code: "setting_user_only", message: ControlStrings.format(
            "control.error.settingUserOnly",
            "%1$@ can be changed only by you: use Settings, or `cmux settings set %1$@ <value> --confirm` and approve it in cmux",
            key), data: ["key": .string(key)])
    }

    static func declined(_ key: String) -> ControlError {
        ControlError(code: "setting_user_only", message: ControlStrings.format(
            "control.error.settingUserOnlyDeclined", "%1$@ was not changed: the confirmation was declined", key),
            data: ["key": .string(key), "declined": true])
    }
}
