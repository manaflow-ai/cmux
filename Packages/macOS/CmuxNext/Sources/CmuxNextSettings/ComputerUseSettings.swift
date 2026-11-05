public import Foundation

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
/// `livePreview` (on by default) shows a small live view of the app an agent
/// drives at the top right of that agent's chat.
/// `groundingFallback` (off by default; the upstream driver only) gives agents
/// `point_at_element`, which asks a vision grounding model at
/// `groundingEndpoint` where an element is when a window's accessibility tree
/// is thin. The window's screenshot goes to that endpoint, so only a loopback
/// address may be plain http (scripts/measure/grounding-eval/serve-mlx.sh
/// serves one on this Mac).
public nonisolated struct ComputerUseSettings: Sendable, Equatable {
    public static let enabledPath = ["computerUse", "enabled"]
    public static let driverPath = ["computerUse", "driver"]
    public static let livePreviewPath = ["computerUse", "livePreview"]
    public static let groundingFallbackPath = ["computerUse", "groundingFallback"]
    public static let groundingEndpointPath = ["computerUse", "groundingEndpoint"]
    public static let defaultGroundingEndpoint = "http://127.0.0.1:8080/v1"
    public var enabled = false
    public var driver: ComputerUseDriver = .legacy
    public var livePreview = true
    public var groundingFallback = false
    public var groundingEndpoint = ComputerUseSettings.defaultGroundingEndpoint

    /// The endpoint the helper may use: nil when the fallback is off or the
    /// address is not https, or http to this Mac.
    public var groundingEndpointURL: URL? {
        guard groundingFallback else { return nil }
        let text = groundingEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        if scheme == "https" { return url }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host) ? url : nil
    }

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["computerUse"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.choice("driver", ComputerUseDriver.self) { settings.driver = value }
        if let value = reader.bool("livePreview") { settings.livePreview = value }
        if let value = reader.bool("groundingFallback") { settings.groundingFallback = value }
        if let value = reader.string("groundingEndpoint") { settings.groundingEndpoint = value }
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
                summary: SettingsText.keyed("settings.computerUse.enabled.summary", "Lets agents see and use your apps"),
                kind: .toggle, default: .bool(ComputerUseSettings().enabled),
                keywords: ["computer use", "agents", "automation", "screen recording", "accessibility", "helper"]
            ),
            SettingDescriptor(
                ComputerUseSettings.driverPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.driver", "Computer Use Driver"),
                help: SettingsText.keyed("settings.computerUse.driver.help",
                                         "Legacy runs the current cmux Computer Use helper. Upstream runs the new helper built on the upstream Cua Driver; macOS asks for its permissions separately."),
                summary: SettingsText.keyed("settings.computerUse.driver.summary", "Which helper runs Computer Use"),
                kind: .choice([
                    SettingChoice(ComputerUseDriver.legacy.rawValue,
                                  SettingsText.keyed("settings.computerUse.driver.legacy", "Legacy")),
                    SettingChoice(ComputerUseDriver.upstream.rawValue,
                                  SettingsText.keyed("settings.computerUse.driver.upstream", "Upstream")),
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
                ComputerUseSettings.groundingFallbackPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.groundingFallback", "Find Elements with a Vision Model"),
                help: SettingsText.keyed("settings.computerUse.groundingFallback.help",
                                         "When an app shows agents few named controls (canvas apps, games, Electron apps), agents can ask a vision model where an element is. The app window's screenshot goes to the model address below. Upstream driver only."),
                summary: SettingsText.keyed("settings.computerUse.groundingFallback.summary", "Lets agents find unnamed controls with a vision model"),
                kind: .toggle, default: .bool(ComputerUseSettings().groundingFallback),
                keywords: ["computer use", "grounding", "vision", "model", "canvas", "accessibility", "point", "element"]
            ),
            SettingDescriptor(
                ComputerUseSettings.groundingEndpointPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.groundingEndpoint", "Vision Model Address"),
                help: SettingsText.keyed("settings.computerUse.groundingEndpoint.help",
                                         "An OpenAI-compatible server for the vision model, such as one on this Mac at http://127.0.0.1:8080/v1. Any other address must use https."),
                summary: SettingsText.keyed("settings.computerUse.groundingEndpoint.summary", "Where the vision model runs"),
                kind: .url, default: .string(ComputerUseSettings().groundingEndpoint),
                keywords: ["computer use", "grounding", "vision", "model", "endpoint", "server", "address"]
            ),
        ]
    }
}
