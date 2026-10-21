public import Foundation

/// `deviceHub.*` in cmux.json, the Development section's Device Hub group.
/// Every build has a built-in device hub (docs/device-hub/PROTOCOL.md,
/// workers/device-hub/DEPLOY.md): DEV builds the dev hub, every other build
/// the production hub. Only DEV builds read the key (the section shows only
/// there); every other build ignores it.
/// - `url` (empty by default): a DEV build's override of the hub address.
///   Empty uses the built-in hub; an address that is not valid turns the hub off.
public nonisolated struct DeviceHubSettings: Sendable, Equatable {
    public static let urlPath = ["deviceHub", "url"]
    public var url = ""

    public init() {}

    /// The hub's address when `url` is an http(s) address with a host; nil (off) otherwise.
    public var baseURL: URL? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The dev hub: accepts the Stack production and development projects (DEV builds sign in to either).
    public static let developmentHubURL = URL(string: "https://cmux-device-hub-dev.debussy.workers.dev")
    /// The production hub: accepts the Stack production project only.
    public static let productionHubURL = URL(string: "https://cmux-device-hub.debussy.workers.dev")

    /// The hub a build uses when `url` is empty: DEV builds the dev hub, every other build the production hub.
    public static func builtInBaseURL(isDebugBuild: Bool) -> URL? {
        isDebugBuild ? developmentHubURL : productionHubURL
    }

    /// The hub this build uses. Release builds always use the production hub.
    /// DEV builds use `url` when it is set, the dev hub when it is empty, and
    /// none (nil, off) when it is not a valid address, so the mistake shows.
    public func resolvedBaseURL(isDebugBuild: Bool) -> URL? {
        guard isDebugBuild else { return Self.builtInBaseURL(isDebugBuild: false) }
        guard url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return baseURL }
        return Self.builtInBaseURL(isDebugBuild: true)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["deviceHub"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.string("url") { settings.url = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// The Development section's Device Hub row.
nonisolated enum DeviceHubSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.deviceHub", "Device Hub")
        return [
            SettingDescriptor(
                DeviceHubSettings.urlPath, section: .development, group: group,
                title: SettingsText.keyed("settings.deviceHub.url", "Device Hub Address"),
                help: SettingsText.keyed("settings.deviceHub.url.help",
                                         "Overrides the device hub this build signs its devices in to, for Mac Screen sharing between your devices. Leave it empty to use the built-in hub."),
                summary: SettingsText.keyed("settings.deviceHub.url.summary", "Device hub address"),
                kind: .url, default: .string(DeviceHubSettings().url),
                keywords: ["device hub", "devices", "mac screen", "backend", "development", "debug"]
            ),
        ]
    }
}
