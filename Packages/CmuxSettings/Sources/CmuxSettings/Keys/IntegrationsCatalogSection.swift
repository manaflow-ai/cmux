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
