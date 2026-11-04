/// Which Computer Use driver the helper runs (`computerUse.driver`).
public nonisolated enum ComputerUseDriver: String, Sendable, Hashable, CaseIterable {
    /// The classic cmux app's cmux-cua helper (an opt-out for one release).
    case legacy
    /// cmux Remote's Computer Use worker, upstream Cua Driver in process (docs/cmux-remote.md).
    case upstream
}

/// The `computerUse.mode` values (docs/computer-use-approvals.md, Modes), in order of trust.
public nonisolated enum ComputerUseMode: String, Sendable, Hashable, CaseIterable {
    case ask
    case bounded
    case standard
    case unrestricted

    /// Higher trusts agents more; only a person may raise it.
    public var trust: Int {
        switch self {
        case .ask: 0
        case .bounded: 1
        case .standard: 2
        case .unrestricted: 3
        }
    }

    public func raises(over current: ComputerUseMode) -> Bool { trust > current.trust }
}

/// `computerUse.*` in cmux.json. `enabled` (off by default) lets cmux start
/// the Developer ID signed cmux Computer Use helper, so agents can see and
/// use other apps. Off, no helper starts and macOS asks for nothing.
/// `driver` ("upstream" by default) picks the engine: "upstream" runs Computer Use in cmux
/// Remote, the one process that holds the grants; "legacy" borrows the classic cmux app's
/// helper, an opt-out kept for one release.
/// `livePreview` (on by default) shows a small live view of the app an agent
/// drives at the top right of that agent's chat.
public nonisolated struct ComputerUseSettings: Sendable, Equatable {
    public static let enabledPath = ["computerUse", "enabled"]
    public static let driverPath = ["computerUse", "driver"]
    public static let livePreviewPath = ["computerUse", "livePreview"]
    public static let modePath = ["computerUse", "mode"]
    public static let phoneAlwaysAllowPath = ["computerUse", "phoneAlwaysAllow"]
    public var enabled = false
    /// How agents may use apps on this Mac (docs/computer-use-approvals.md, Modes).
    /// Standard by default: per-app asking (`ask`) is off until the person turns it on (D24).
    public var mode: ComputerUseMode = .standard
    /// The owner's iPhone may answer "Always Allow <App>" (Face ID signed); off, it offers
    /// Allow Once, Allow for This Session and Deny only.
    public var phoneAlwaysAllow = false
    public var driver: ComputerUseDriver = .upstream
    public var livePreview = true

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["computerUse"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.choice("driver", ComputerUseDriver.self) { settings.driver = value }
        if let value = reader.bool("livePreview") { settings.livePreview = value }
        if let value = reader.choice("mode", ComputerUseMode.self) { settings.mode = value }
        if let value = reader.bool("phoneAlwaysAllow") { settings.phoneAlwaysAllow = value }
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
                                         "Lets agents see and use your apps through cmux Remote. Grant it Accessibility and Screen Recording once; cmux never needs a relaunch."),
                summary: SettingsText.keyed("settings.computerUse.enabled.summary", "Lets agents see and use your apps"),
                kind: .toggle, default: .bool(ComputerUseSettings().enabled),
                keywords: ["computer use", "agents", "automation", "screen recording", "accessibility", "helper"]
            ),
            SettingDescriptor(
                ComputerUseSettings.driverPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.driver", "Computer Use Driver"),
                help: SettingsText.keyed("settings.computerUse.driver.help",
                                         "cmux Remote runs Computer Use and holds its macOS permissions, with no relaunch after you grant them. Classic Helper uses the cmux Computer Use helper of an installed classic cmux."),
                summary: SettingsText.keyed("settings.computerUse.driver.summary", "Which helper runs Computer Use"),
                kind: .choice([
                    SettingChoice(ComputerUseDriver.legacy.rawValue,
                                  SettingsText.keyed("settings.computerUse.driver.legacy", "Classic Helper")),
                    SettingChoice(ComputerUseDriver.upstream.rawValue,
                                  SettingsText.keyed("settings.computerUse.driver.upstream", "cmux Remote")),
                ]),
                default: .string(ComputerUseSettings().driver.rawValue),
                keywords: ["computer use", "driver", "cua", "upstream", "legacy", "helper"]
            ),
            SettingDescriptor(
                ComputerUseSettings.livePreviewPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.livePreview", "Live Preview in Chat"),
                help: SettingsText.keyed("settings.computerUse.livePreview.help",
                                         "While an agent uses an app, its chat shows a small live view of that app. Click the view to open Agent Activity."),
                summary: SettingsText.keyed("settings.computerUse.livePreview.summary", "Shows the app an agent uses in its chat"),
                kind: .toggle, default: .bool(ComputerUseSettings().livePreview),
                keywords: ["computer use", "live preview", "preview", "agent activity", "screenshot", "chat"]
            ),
            SettingDescriptor(
                ComputerUseSettings.modePath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.mode", "Agents Using Apps"),
                help: SettingsText.keyed("settings.computerUse.mode.help",
                                         "Standard (the default) lets agents click and type in your apps without asking; cmux still never lets them use password managers, login or security prompts, System Settings or cmux. Ask Before Using Apps asks you the first time an agent uses each app, on this Mac and on your iPhone. Approved Apps Only runs the apps you set up and asks for the rest. Unrestricted never asks; use it only on a disposable machine."),
                summary: SettingsText.keyed("settings.computerUse.mode.summary", "When agents ask before using an app"),
                kind: .choice([
                    SettingChoice(ComputerUseMode.ask.rawValue, SettingsText.keyed("settings.computerUse.mode.ask", "Ask Before Using Apps")),
                    SettingChoice(ComputerUseMode.bounded.rawValue, SettingsText.keyed("settings.computerUse.mode.bounded", "Approved Apps Only")),
                    SettingChoice(ComputerUseMode.standard.rawValue, SettingsText.keyed("settings.computerUse.mode.standard", "Standard")),
                    SettingChoice(ComputerUseMode.unrestricted.rawValue, SettingsText.keyed("settings.computerUse.mode.unrestricted", "Unrestricted")),
                ]),
                default: .string(ComputerUseSettings().mode.rawValue),
                keywords: ["computer use", "approval", "approve", "ask", "permission", "mode", "apps", "bounded", "unrestricted"]
            ),
            SettingDescriptor(
                ComputerUseSettings.phoneAlwaysAllowPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.phoneAlwaysAllow", "Allow Always from iPhone"),
                help: SettingsText.keyed("settings.computerUse.phoneAlwaysAllow.help",
                                         "Your iPhone can answer Always Allow for an app, after Face ID. Off, it can allow once or for one agent session, and Always Allow stays on this Mac."),
                summary: SettingsText.keyed("settings.computerUse.phoneAlwaysAllow.summary", "Lets your iPhone save an app approval"),
                kind: .toggle, default: .bool(ComputerUseSettings().phoneAlwaysAllow),
                keywords: ["computer use", "iphone", "phone", "always allow", "face id", "approval"]
            ),
        ]
    }
}
