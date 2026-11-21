public import Foundation

/// `app.sendAnonymousTelemetry` in cmux-next.json: whether this Mac sends crash reports and anonymous
/// performance timing (Settings > Privacy and Security > Anonymous Telemetry). On until the person
/// turns it off; agents may not change it (privacy).
///
/// The consent the crash reporter reads once per launch stays the app's own `sendAnonymousTelemetry`
/// preference (`CrashReportingPolicy.telemetryOptIn(in:)`, shared with classic's same-channel bundle),
/// so the row mirrors into it: every write of the row sets or removes the preference
/// (`SettingsController.setSetting`), and the launch migration brings an explicit off from the
/// preference into the file (`importTelemetryConsent`). The managed `DisableTelemetry` policy forces
/// the row off and locks it (`EffectiveSettings.merge`).
public nonisolated struct AnonymousTelemetrySetting: Sendable {
    // `configPath` and `fallback` (on) are generated from schemas/settings/source/hang-reports.json.

    /// The app's preference the crash reporter reads (`CrashReportingPolicy.telemetryKey`; this
    /// module does not link the crash reporter).
    public static let defaultsKey = "sendAnonymousTelemetry"
    /// The managed policy that turns telemetry off whatever the person chose
    /// (`CrashReportingPolicy.disableTelemetryPolicyKey`).
    public static let disableTelemetryPolicyKey = "DisableTelemetry"
    /// The row's dotted key.
    public static var key: String { configPath.joined(separator: ".") }

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: off only for a literal `false`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.boolValue ?? Self.fallback
    }

    /// Whether the managed policies force telemetry off, read the way the crash reporter reads them.
    static func managedDisables(_ forced: [String: JSONValue]) -> Bool {
        forced[disableTelemetryPolicyKey]?.boolValue == true
    }

    /// Writes a row write into the preference: a toggle value sets it, nil (reset, unset) removes it,
    /// which means on.
    static func mirror(_ value: JSONValue?, into defaults: UserDefaults) {
        if let on = value?.boolValue {
            defaults.set(on, forKey: defaultsKey)
        } else if value == nil {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}

extension SettingsController {
    /// The launch step that keeps the row and the preference the same: a value the file sets goes
    /// into the preference; a file that leaves the key out takes an explicit off from the preference
    /// (turned off in classic, or with `defaults write`), so the row shows the truth. Never turns
    /// telemetry on for someone who turned it off. A managed key is left alone.
    public func importTelemetryConsent() async throws {
        let path = AnonymousTelemetrySetting.configPath
        guard managedKeys[AnonymousTelemetrySetting.key] == nil else { return }
        if let stored = try await file.value(at: path) {
            if stored.boolValue != nil { AnonymousTelemetrySetting.mirror(stored, into: telemetryDefaults) }
            return
        }
        let defaults = telemetryDefaults
        guard defaults.object(forKey: AnonymousTelemetrySetting.defaultsKey) != nil,
              !defaults.bool(forKey: AnonymousTelemetrySetting.defaultsKey) else { return }
        try await file.set(.bool(false), at: path)
        await reloadAfterWrite()
    }
}
