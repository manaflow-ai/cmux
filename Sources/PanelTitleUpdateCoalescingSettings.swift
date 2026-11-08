import Foundation
import CmuxSettings

enum PanelTitleUpdateCoalescingSettings {
    private nonisolated static let terminalSettings = SettingCatalog().terminal
    nonisolated static let defaultDelay: TimeInterval = 1.0 / 30.0
    nonisolated static let minimumDelayMilliseconds = 33
    nonisolated static let maximumDelayMilliseconds = 5_000

    nonisolated static func isEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateCoalescingEnabled)
    }

    nonisolated static func diagnosticsEnabled(settings: any SettingsReading) -> Bool {
        settings.value(for: terminalSettings.titleUpdateDiagnostics)
    }

    nonisolated static func delay(settings: any SettingsReading) -> TimeInterval {
        guard isEnabled(settings: settings) else { return defaultDelay }
        let rawMilliseconds = settings.value(for: terminalSettings.titleUpdateCoalescingMilliseconds)
        let clampedMilliseconds = min(max(rawMilliseconds, minimumDelayMilliseconds), maximumDelayMilliseconds)
        return TimeInterval(clampedMilliseconds) / 1_000.0
    }

    nonisolated static func configuredDelayMilliseconds(settings: any SettingsReading) -> Int {
        Int((delay(settings: settings) * 1_000).rounded())
    }
}
