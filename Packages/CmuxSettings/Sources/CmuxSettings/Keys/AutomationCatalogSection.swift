import Foundation

/// Settings under the dotted-id prefix `automation.*`.
public struct AutomationCatalogSection: SettingCatalogSection {
    public let socketControlMode = DefaultsKey<SocketControlMode>(
        id: "automation.socketControlMode",
        defaultValue: .cmuxOnly,
        userDefaultsKey: "socketControlMode"
    )

    public let socketPassword = SecretFileKey(
        id: "automation.socketPassword",
        fileName: "socket-control-password"
    )

    public let claudeCodeIntegration = DefaultsKey<Bool>(
        id: "automation.claudeCodeIntegration",
        defaultValue: false,
        userDefaultsKey: "claudeCodeHooksEnabled"
    )

    public let claudeBinaryPath = DefaultsKey<String>(
        id: "automation.claudeBinaryPath",
        defaultValue: "",
        userDefaultsKey: "claudeCodeCustomClaudePath"
    )

    public let ripgrepBinaryPath = DefaultsKey<String>(
        id: "automation.ripgrepBinaryPath",
        defaultValue: "",
        userDefaultsKey: "ripgrepCustomBinaryPath"
    )

    public let suppressSubagentNotifications = DefaultsKey<Bool>(
        id: "automation.suppressSubagentNotifications",
        defaultValue: false,
        userDefaultsKey: "suppressSubagentNotifications"
    )

    // Several agent-integration toggles are intentionally exposed under both
    // `automation.*` (this catalog) and `integrations.*` (IntegrationsCatalogSection)
    // with the same `userDefaultsKey`, so writes through either namespace land
    // on the same persisted value. The shared keys are claudeCode*, cursor*,
    // gemini*, kiro* (including kiroNotificationLevel), amp*,
    // ripgrepCustomBinaryPath, and suppressSubagentNotifications. There is no
    // precedence ambiguity because both DefaultsKey wrappers read/write the
    // same `UserDefaults` slot — the dual namespace exists to keep the JSON
    // config UX (`automation.*`) and the Settings-catalog UX
    // (`integrations.*`) separately discoverable.
    public let ampIntegration = DefaultsKey<Bool>(
        id: "automation.ampIntegration",
        defaultValue: true,
        userDefaultsKey: "ampHooksEnabled"
    )

    public let cursorIntegration = DefaultsKey<Bool>(
        id: "automation.cursorIntegration",
        defaultValue: false,
        userDefaultsKey: "cursorHooksEnabled"
    )

    public let geminiIntegration = DefaultsKey<Bool>(
        id: "automation.geminiIntegration",
        defaultValue: false,
        userDefaultsKey: "geminiHooksEnabled"
    )

    public let kiroIntegration = DefaultsKey<Bool>(
        id: "automation.kiroIntegration",
        defaultValue: true,
        userDefaultsKey: "kiroHooksEnabled"
    )

    public let kiroNotificationLevel = DefaultsKey<String>(
        id: "automation.kiroNotificationLevel",
        defaultValue: "standard",
        userDefaultsKey: "kiroNotificationLevel"
    )

    public let portBase = DefaultsKey<Int>(
        id: "automation.portBase",
        defaultValue: 9100,
        userDefaultsKey: "cmuxPortBase"
    )

    public let portRange = DefaultsKey<Int>(
        id: "automation.portRange",
        defaultValue: 10,
        userDefaultsKey: "cmuxPortRange"
    )

    public init() {}
}
