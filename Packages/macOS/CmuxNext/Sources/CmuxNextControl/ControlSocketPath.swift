public import Foundation

/// Socket path conventions shared with the old app and the `cmux` CLI, so
/// `CMUX_TAG=<tag> cmux …`, `--socket`, and implicit discovery find
/// cmux-next without CLI changes:
///
/// | Build | Path |
/// | --- | --- |
/// | tagged debug (bundle `com.cmuxterm.app.debug.<tag>`, or a bundled tag) | `/tmp/cmux-debug-<tag>.sock` |
/// | untagged debug | `/tmp/cmux-debug.sock` |
/// | nightly / rc / staging (optionally tagged) | `/tmp/cmux-<channel>[-<tag>].sock` |
/// | release | `~/.local/state/cmux/cmux.sock` |
///
/// The inputs are this app's own identity only. Inherited environment
/// (`CMUX_SOCKET_PATH`, `CMUX_TAG`, `CMUX_BUNDLE_ID` from a shell inside
/// another cmux) never reaches this function; see ``LaunchIdentity``.
/// Tags are sanitized the same way (`[^a-z0-9]+` -> `-`).
public struct ControlSocketPath: Sendable {
    public static let shared = Self()
    public let debugBundleID = "com.cmuxterm.app.debug"
    let channelBundleIDs = [
        ("com.cmuxterm.app.nightly", "nightly"),
        ("com.cmuxterm.app.rc", "rc"),
        ("com.cmuxterm.app.staging", "staging"),
    ]

    /// `tag` applies to the plain debug bundle only; a tagged bundle id
    /// carries its own tag.
    public func resolve(
        bundleID: String?,
        tag: String?,
        isDebugBuild: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let bundle = bundleID?.trimmingCharacters(in: .whitespaces) ?? ""
        for (channelID, channel) in channelBundleIDs {
            if bundle == channelID { return "/tmp/cmux-\(channel).sock" }
            if bundle.hasPrefix(channelID + "."), let slug = sanitize(String(bundle.dropFirst(channelID.count + 1))) {
                return "/tmp/cmux-\(channel)-\(slug).sock"
            }
        }
        if let slug = bundleTag(bundle) {
            return "/tmp/cmux-debug-\(slug).sock"
        }
        if bundle == debugBundleID || (bundle.isEmpty && isDebugBuild) {
            if let tag = tag.flatMap(sanitize) {
                return "/tmp/cmux-debug-\(tag).sock"
            }
            return "/tmp/cmux-debug.sock"
        }
        if isDebugBuild {
            return "/tmp/cmux-debug.sock"
        }
        return home.appending(path: ".local/state/cmux/cmux.sock").path
    }

    /// The tag a tagged bundle id carries (`com.cmuxterm.app.debug.<tag>`
    /// or `com.cmuxterm.app.<channel>.<tag>`), sanitized.
    public func bundleTag(_ bundleID: String?) -> String? {
        let bundle = bundleID?.trimmingCharacters(in: .whitespaces) ?? ""
        for prefix in [debugBundleID] + channelBundleIDs.map(\.0) where bundle.hasPrefix(prefix + ".") {
            return sanitize(String(bundle.dropFirst(prefix.count + 1)))
        }
        return nil
    }

    public func sanitize(_ raw: String) -> String? {
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
