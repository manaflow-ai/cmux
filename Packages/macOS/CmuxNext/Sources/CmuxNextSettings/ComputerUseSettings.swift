/// Which Computer Use driver the helper runs (`computerUse.driver`).
public nonisolated enum ComputerUseDriver: String, Sendable, Hashable, CaseIterable {
    /// The cmux-cua 0.8.12 helper (today's path, unchanged).
    case legacy
    /// The cmux Computer Use helper v2 with upstream Cua Driver in process.
    case upstream
}

/// `computerUse.*` in cmux.json. `enabled` (off by default) lets cmux start
/// the Developer ID signed cmux Computer Use helper, so agents can see and
/// use other apps. Off, no helper starts and macOS asks for nothing.
/// `driver` ("legacy" by default) picks the helper: "upstream" starts the
/// helper v2 (a DEV build embeds a dev helper, com.cmuxterm.cua.dev).
public nonisolated struct ComputerUseSettings: Sendable, Equatable {
    public static let enabledPath = ["computerUse", "enabled"]
    public static let driverPath = ["computerUse", "driver"]
    public var enabled = false
    public var driver: ComputerUseDriver = .legacy

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["computerUse"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        // RED STUB (commit 1): the driver is not read.
        diagnostics = reader.diagnostics
        return settings
    }
}

/// The Computer Use settings rows.
nonisolated enum ComputerUseSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.computerUse", "Computer Use")
        return [
            SettingDescriptor(
                ComputerUseSettings.enabledPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.enabled", "Computer Use"),
                help: SettingsText.keyed("settings.computerUse.enabled.help",
                                         "Lets agents see and use your apps through the signed cmux Computer Use helper. macOS asks for Accessibility and Screen Recording when you first allow them."),
                kind: .toggle, default: .bool(ComputerUseSettings().enabled),
                keywords: ["computer use", "agents", "automation", "screen recording", "accessibility", "helper"]
            ),
            SettingDescriptor(
                ComputerUseSettings.driverPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.driver", "Computer Use Driver"),
                help: SettingsText.keyed("settings.computerUse.driver.help",
                                         "Legacy runs the current cmux Computer Use helper. Upstream runs the new helper built on the upstream Cua Driver; macOS asks for its permissions separately."),
                kind: .choice([
                    SettingChoice(ComputerUseDriver.legacy.rawValue,
                                  SettingsText.keyed("settings.computerUse.driver.legacy", "Legacy")),
                    SettingChoice(ComputerUseDriver.upstream.rawValue,
                                  SettingsText.keyed("settings.computerUse.driver.upstream", "Upstream")),
                ]),
                default: .string(ComputerUseSettings().driver.rawValue),
                keywords: ["computer use", "driver", "cua", "upstream", "legacy", "helper"]
            ),
        ]
    }
}
