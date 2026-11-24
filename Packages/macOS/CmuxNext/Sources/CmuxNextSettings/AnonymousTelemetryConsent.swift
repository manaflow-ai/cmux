import Foundation

/// The person's opt-in for crash reports and anonymous analytics (`app.sendAnonymousTelemetry`,
/// Settings > Privacy and Security > Crash Reports and Analytics). Off until the person turns it on
/// (Leo, 2026-11-24: "whatever we do, we need to make sure it's opt out by defautl i assume?").
///
/// The person's own write of the setting (`SettingWriter.user`: the Settings switch after its
/// consent prompt, Toggle Setting, a CLI call the confirmation sheet approved) is copied into the
/// app's `sendAnonymousTelemetry` preference before the file write. Crash reporting reads that
/// preference at the next launch (`CrashReportingPolicy.telemetryOptIn(in:)`); the Chief host
/// re-reads it while it runs. A synced or hand-edited file alone never turns sending on here.
@MainActor
public enum AnonymousTelemetryConsent {
    /// The setting's path in `cmux-next.json` (schemas/settings/source/hang-reports.json).
    public static let configPath = HangReportsSettingsSchema.sendAnonymousTelemetryPath
    /// The app preference crash reporting and the Chief host read (`CrashReportingPolicy.telemetryKey`).
    public static let preferenceKey = "sendAnonymousTelemetry"

    /// Adds the copy to `settings.userWillWrite`, after whatever hook is already there (hang
    /// reports' consent record), so both run for each write and both undos run if it fails.
    public static func install(on settings: SettingsController, defaults: UserDefaults = .standard) {
        let previous = settings.userWillWrite
        settings.userWillWrite = { descriptor, value in
            let earlier = previous?(descriptor, value)
            let mine = recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
            guard earlier != nil || mine != nil else { return nil }
            return {
                mine?()
                earlier?()
            }
        }
    }

    /// The person's write of `path`: `true` turns the preference on, anything else turns it off.
    /// Returns the undo that puts the earlier preference back when the file write then fails, so a
    /// failed `true` sends nothing.
    public static func recordUserWrite(defaults: UserDefaults, path: [String], value: JSONValue?) -> (@MainActor () -> Void)? {
        guard path == configPath else { return nil }
        let key = preferenceKey
        let earlier = defaults.object(forKey: key) as? Bool
        defaults.set(value == .bool(true), forKey: key)
        return {
            if let earlier { defaults.set(earlier, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}
