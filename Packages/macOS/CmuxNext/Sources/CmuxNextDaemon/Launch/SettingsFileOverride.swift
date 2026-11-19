public import Foundation

/// The settings file a launch runs on when it is not the shared
/// `~/.config/cmux/cmux-next.json`: `CMUX_NEXT_CONFIG_FILE`, as the absolute path of the file the
/// app itself opens (`CmuxConfigFile.defaultURL`: unset or empty is the shared file, `~` expanded,
/// a relative path against this process's directory). The app's terminals, its daemon, the acpmux
/// daemon (`LaunchIdentity.terminalEnvironment`) and the Chief owner (`DaemonLauncher.chiefEnvironment`)
/// all get this one path, so every reader names the same file.
public struct SettingsFileOverride: Sendable, Equatable {
    /// `CmuxConfigFile.overrideKey`; cmux-tui `user_settings::CONFIG_OVERRIDE`.
    public static let key = "CMUX_NEXT_CONFIG_FILE"

    /// The absolute path, or nil on the shared file.
    public let path: String?

    /// The override in `environment`; `~/` is `home`.
    public init(environment: [String: String], home: URL) {
        guard let raw = environment[Self.key], !raw.isEmpty else {
            path = nil
            return
        }
        if raw == "~" {
            path = home.path
        } else if raw.hasPrefix("~/") {
            path = home.appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        }
    }
}
