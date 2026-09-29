public import Foundation

/// Socket path conventions shared with the old app and the `cmux` CLI, so
/// `CMUX_TAG=<tag> cmux …`, `--socket`, and implicit discovery find
/// cmux-next without CLI changes:
///
/// | Build | Path |
/// | --- | --- |
/// | `CMUX_SOCKET_PATH` set | that path |
/// | tagged debug (`CMUX_TAG`, or bundle `com.cmuxterm.app.debug.<tag>`) | `/tmp/cmux-debug-<tag>.sock` |
/// | untagged debug | `/tmp/cmux-debug.sock` |
/// | nightly / rc / staging (optionally tagged) | `/tmp/cmux-<channel>[-<tag>].sock` |
/// | release | `~/.local/state/cmux/cmux.sock` |
///
/// Tags are sanitized the same way (`[^a-z0-9]+` -> `-`).
public enum ControlSocketPath {
    public static let debugBundleID = "com.cmuxterm.app.debug"
    static let channelBundleIDs = [
        ("com.cmuxterm.app.nightly", "nightly"),
        ("com.cmuxterm.app.rc", "rc"),
        ("com.cmuxterm.app.staging", "staging"),
    ]

    public static func resolve(
        bundleID: String?,
        environment: [String: String],
        isDebugBuild: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let explicit = environment["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return explicit
        }
        let bundle = bundleID?.trimmingCharacters(in: .whitespaces) ?? ""
        for (channelID, channel) in channelBundleIDs {
            if bundle == channelID { return "/tmp/cmux-\(channel).sock" }
            if bundle.hasPrefix(channelID + "."), let slug = sanitize(String(bundle.dropFirst(channelID.count + 1))) {
                return "/tmp/cmux-\(channel)-\(slug).sock"
            }
        }
        if bundle.hasPrefix(debugBundleID + "."), let slug = sanitize(String(bundle.dropFirst(debugBundleID.count + 1))) {
            return "/tmp/cmux-debug-\(slug).sock"
        }
        if bundle == debugBundleID || (bundle.isEmpty && isDebugBuild) {
            if let tag = environment["CMUX_TAG"].flatMap(sanitize) {
                return "/tmp/cmux-debug-\(tag).sock"
            }
            return "/tmp/cmux-debug.sock"
        }
        if isDebugBuild {
            return "/tmp/cmux-debug.sock"
        }
        return home.appending(path: ".local/state/cmux/cmux.sock").path
    }

    public static func sanitize(_ raw: String) -> String? {
        let slug = raw.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }
}

/// Who may use the socket. Raw values match the old app's
/// `SocketControlMode` and the cmux.json `automation.socketControlMode`
/// strings.
public enum ControlAccessMode: String, Sendable, CaseIterable {
    /// No socket.
    case off
    /// Only processes descended from the app (its terminals) may connect.
    case cmuxOnly
    /// Any process of the same user.
    case automation
    /// Same user, after `auth <password>` or `auth.login`.
    case password
    /// Any local process. Developer-only.
    case allowAll

    /// Socket file permissions for this mode.
    var filePermissions: mode_t {
        self == .allowAll ? 0o666 : 0o600
    }
}
