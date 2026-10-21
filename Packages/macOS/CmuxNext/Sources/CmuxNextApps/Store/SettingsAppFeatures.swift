public import CmuxNextSettings

/// The App Store Features tab's settings (``AppFeatureSettings``): reads the snapshot in
/// effect, so a card follows every writer (Settings, `cmux settings set`, an agent), and writes
/// through the schema-validated path with the person's authority (a button press on the page).
@MainActor
public final class SettingsAppFeatures: AppFeatureSettings {
    private let settings: () -> SettingsController?

    public init(settings: @escaping () -> SettingsController?) {
        self.settings = settings
    }

    public func isAvailable(_ feature: AppFeature) -> Bool { SettingsSchema.descriptor(for: feature.path) != nil }

    public func isOn(_ feature: AppFeature) -> Bool {
        guard let settings = settings(), let descriptor = SettingsSchema.descriptor(for: feature.path) else { return false }
        return descriptor.effectiveValue(in: settings.snapshot.root) == Self.onValue(feature)
    }

    public func isManaged(_ feature: AppFeature) -> Bool { settings()?.managedKeys[feature.setting] != nil }

    public func set(_ feature: AppFeature, on: Bool) async throws {
        guard let settings = settings(), let descriptor = SettingsSchema.descriptor(for: feature.path) else {
            throw SettingRefused(key: feature.setting, value: Self.onValue(feature))
        }
        try await settings.setSetting(descriptor, to: Self.value(feature, on: on, default: descriptor.defaultValue), by: .user)
    }

    /// The value that means on: `true`, or the feature's choice.
    nonisolated static func onValue(_ feature: AppFeature) -> JSONValue {
        switch feature.on {
        case .toggle: .bool(true)
        case .choice(let value): .string(value)
        }
    }

    /// What Get (`on`) or Remove writes. Remove takes a choice key out of the file, so its
    /// default (off) applies; a toggle whose default is off leaves the file too, and one whose
    /// default is on is written `false`.
    nonisolated static func value(_ feature: AppFeature, on: Bool, default defaultValue: JSONValue?) -> JSONValue? {
        if on { return onValue(feature) }
        switch feature.on {
        case .toggle: return defaultValue == .bool(true) ? .bool(false) : nil
        case .choice: return nil
        }
    }
}
