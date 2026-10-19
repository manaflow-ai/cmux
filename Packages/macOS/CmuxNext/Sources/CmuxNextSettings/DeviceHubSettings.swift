public import Foundation

/// `deviceHub.*` in cmux.json, the Development section's Device Hub group.
/// Only DEV builds read it (the section shows only there); every other build
/// ignores the key.
/// - `url` (empty by default): the device hub's address
///   (docs/device-hub/PROTOCOL.md). Empty turns the device hub off.
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
                                         "The device hub this build signs its devices in to, for Mac Screen sharing between your devices. Empty turns it off."),
                summary: SettingsText.keyed("settings.deviceHub.url.summary", "Device hub address"),
                kind: .url, default: .string(DeviceHubSettings().url),
                keywords: ["device hub", "devices", "mac screen", "backend", "development", "debug"]
            ),
        ]
    }
}
