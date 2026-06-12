import Foundation

/// Settings under the dotted-id prefix `integrations.*` — external
/// agent / editor / search integrations.
public struct IntegrationsCatalogSection: SettingCatalogSection {
    public let claudeCodeHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.claudeCode.hooksEnabled",
        defaultValue: false,
        userDefaultsKey: "claudeCodeHooksEnabled"
    )

    public let claudeCodeCustomClaudePath = DefaultsKey<String>(
        id: "integrations.claudeCode.customClaudePath",
        defaultValue: "",
        userDefaultsKey: "claudeCodeCustomClaudePath"
    )

    public let ampHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.amp.hooksEnabled",
        defaultValue: true,
        userDefaultsKey: "ampHooksEnabled"
    )

    public let cursorHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.cursor.hooksEnabled",
        defaultValue: false,
        userDefaultsKey: "cursorHooksEnabled"
    )

    public let geminiHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.gemini.hooksEnabled",
        defaultValue: false,
        userDefaultsKey: "geminiHooksEnabled"
    )

    public let kiroHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.kiro.hooksEnabled",
        defaultValue: true,
        userDefaultsKey: "kiroHooksEnabled"
    )

    // Stored as the raw `minimal` / `standard` / `verbose` string so it stays
    // in sync with the `cmux` CLI's `CMUX_KIRO_NOTIFICATION_LEVEL` env var and
    // the `automation.kiroNotificationLevel` config key.
    public let kiroNotificationLevel = DefaultsKey<String>(
        id: "integrations.kiro.notificationLevel",
        defaultValue: "standard",
        userDefaultsKey: "kiroNotificationLevel"
    )

    public let ripgrepCustomBinaryPath = DefaultsKey<String>(
        id: "integrations.ripgrep.customBinaryPath",
        defaultValue: "",
        userDefaultsKey: "ripgrepCustomBinaryPath"
    )

    public let suppressSubagentNotifications = DefaultsKey<Bool>(
        id: "integrations.suppressSubagentNotifications",
        defaultValue: false,
        userDefaultsKey: "suppressSubagentNotifications"
    )

    public init() {}
}
