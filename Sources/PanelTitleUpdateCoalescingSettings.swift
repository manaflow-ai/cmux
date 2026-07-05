import Foundation
import CmuxSettings

nonisolated enum PanelTitleUpdateCoalescingSettings {
    private nonisolated static let terminalSettings = SettingCatalog().terminal
    nonisolated static let defaultDelay: TimeInterval = 1.0 / 30.0
    nonisolated static let minimumDelayMilliseconds = 33
    nonisolated static let maximumDelayMilliseconds = 5_000

    /// `cmux.json` / UserDefaults storage keys, derived from the catalog so the
    /// config parser and the runtime read path stay on the same source of truth.
    /// Note the JSON-facing key for the interval is `milliseconds`, while the
    /// UserDefaults storage key is historically `delayMilliseconds`.
    nonisolated static let coalescingEnabledKey = terminalSettings.titleUpdateCoalescingEnabled.userDefaultsKey
    nonisolated static let coalescingMillisecondsKey = terminalSettings.titleUpdateCoalescingMilliseconds.userDefaultsKey
    nonisolated static let defaultEnabled = terminalSettings.titleUpdateCoalescingEnabled.defaultValue
    nonisolated static let defaultMilliseconds = terminalSettings.titleUpdateCoalescingMilliseconds.defaultValue

    nonisolated static func isEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateCoalescingEnabled)
    }

    nonisolated static func diagnosticsEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateDiagnostics)
    }

    /// Clamps a requested coalescing interval (milliseconds) into the supported
    /// bounded range. Used both when parsing `cmux.json` and when reading the
    /// stored setting at title-change time.
    nonisolated static func sanitizedDelayMilliseconds(_ value: Int) -> Int {
        min(max(value, minimumDelayMilliseconds), maximumDelayMilliseconds)
    }

    nonisolated static func delay(settings: any SettingsReading) -> TimeInterval {
        guard isEnabled(settings: settings) else { return defaultDelay }
        let rawMilliseconds = settings.value(for: terminalSettings.titleUpdateCoalescingMilliseconds)
        return TimeInterval(sanitizedDelayMilliseconds(rawMilliseconds)) / 1_000.0
    }

    nonisolated static func configuredDelayMilliseconds(settings: any SettingsReading) -> Int {
        Int((delay(settings: settings) * 1_000).rounded())
    }
}
