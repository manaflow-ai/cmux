import Foundation

/// Settings under the dotted-id prefix `integrations.*` — external
/// agent / editor / search integrations.
public struct IntegrationsCatalogSection: SettingCatalogSection {
    // Hook toggles default to `true`, matching the runtime defaults the
    // terminal environment setup has always used (legacy
    // `*IntegrationSettings.defaultHooksEnabled`). The catalog briefly said
    // `false` for claudeCode/cursor/gemini/suppressSubagentNotifications,
    // which made the Settings toggles display OFF while the hooks ran.
    public let claudeCodeHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.claudeCode.hooksEnabled",
        defaultValue: true,
        userDefaultsKey: "claudeCodeHooksEnabled"
    )

    public let claudeCodeCustomClaudePath = DefaultsKey<String>(
        id: "integrations.claudeCode.customClaudePath",
        defaultValue: "",
        userDefaultsKey: "claudeCodeCustomClaudePath"
    )

    public let codexHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.codex.hooksEnabled",
        defaultValue: true,
        userDefaultsKey: "codexHooksEnabled"
    )

    public let ampHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.amp.hooksEnabled",
        defaultValue: true,
        userDefaultsKey: "ampHooksEnabled"
    )

    public let cursorHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.cursor.hooksEnabled",
        defaultValue: true,
        userDefaultsKey: "cursorHooksEnabled"
    )

    public let geminiHooksEnabled = DefaultsKey<Bool>(
        id: "integrations.gemini.hooksEnabled",
        defaultValue: true,
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
        defaultValue: true,
        userDefaultsKey: "suppressSubagentNotifications"
    )

    public let routeClaudeThroughCoderouter = DefaultsKey<Bool>(
        id: "integrations.routeClaudeThroughCoderouter",
        defaultValue: false,
        userDefaultsKey: "cmux.settings.integrations.routeClaudeThroughCoderouter"
    )

    public init() {}
}
