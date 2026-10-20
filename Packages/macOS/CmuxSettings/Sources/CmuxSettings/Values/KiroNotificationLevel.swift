import Foundation

/// Verbosity of the Kiro agent integration's notifications.
///
/// Raw values match the strings the `cmux` CLI accepts in the
/// `CMUX_KIRO_NOTIFICATION_LEVEL` environment variable and the
/// `automation.kiroNotificationLevel` config key, which is also why the
/// catalog persists this setting as its raw `String`
/// (``IntegrationsCatalogSection/kiroNotificationLevel``) rather than as the
/// enum: the stored value is shared wire format with the CLI. Parse it with
/// ``AgentIntegrationSettingsStore/kiroNotificationLevel``, which falls back
/// to ``standard`` for unrecognized stored strings.
public enum KiroNotificationLevel: String, CaseIterable, Sendable, SettingCodable {
    case minimal
    case standard
    case verbose
}
