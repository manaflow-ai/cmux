public import Foundation
import Darwin
import CmuxNextCompat

/// Socket path conventions shared with the old app and the `cmux` CLI, so
/// `CMUX_TAG=<tag> cmux …`, `--socket`, and implicit discovery find
/// cmux-next without CLI changes:
///
/// | Build | Path |
/// | --- | --- |
/// | tagged debug (bundle `com.cmuxterm.app.debug.<tag>`, or a bundled tag) | `~/.local/state/cmux/cmux-debug-<tag>.sock` |
/// | untagged debug | `~/.local/state/cmux/cmux-debug.sock` |
/// | nightly / rc / staging (optionally tagged) | `~/.local/state/cmux/cmux-<channel>[-<tag>].sock` |
/// | release | `~/.local/state/cmux/cmux.sock` |
///
/// The sockets live in the user's own state folder (0700), not in `/tmp`: a
/// host's /tmp cleaner deleted a running app's `/tmp/cmux-debug-<tag>.sock`
/// two nights running (readiness soak, hq#1870). Each non-release socket
/// keeps a compatibility symlink at its old `/tmp` name
/// (``compatibilityLink(bundleID:tag:isDebugBuild:home:)``), so tools that
/// still use the old path connect. A path that would not fit `sun_path`
/// (104 bytes, a long home or tag) stays at the old `/tmp` name.
///
/// The app names its socket through ``BuildIdentity/controlSocket(userHome:)``
/// (per-build isolation S3) and then ``moved(_:home:)``: these names where
/// they belong to one build or DEV tag, else `cmux-<kind>--<key hash>.sock`
/// (the untagged DEV build too).
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

    /// Longest path `sockaddr_un.sun_path` holds, without its terminating NUL.
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// The state folder every cmux-next control socket lives in.
    public func stateDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appending(path: ".local/state/cmux").path
    }

    /// `tag` applies to the plain debug bundle only; a tagged bundle id
    /// carries its own tag.
    public func resolve(
        bundleID: String?,
        tag: String?,
        isDebugBuild: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        moved(tmpPath(bundleID: bundleID, tag: tag, isDebugBuild: isDebugBuild, home: home), home: home).path
    }

    /// A socket's pre-move `/tmp` name `old` in the state folder, and the
    /// `/tmp` name the app keeps as a symlink to it (nil when not moved:
    /// release, or a path too long for `sun_path`).
    public func moved(_ old: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (path: String, link: String?) {
        guard old.hasPrefix("/tmp/") else { return (old, nil) }
        let moved = stateDirectory(home: home) + "/" + old.dropFirst("/tmp/".count)
        return moved.utf8.count <= Self.maxPathBytes ? (moved, old) : (old, nil)
    }

    /// The old `/tmp` name of the socket ``resolve(bundleID:tag:isDebugBuild:home:)``
    /// moved to the state folder, where the app keeps a symlink to it; nil
    /// when the socket was not moved (release, or a path too long to move).
    public func compatibilityLink(
        bundleID: String?,
        tag: String?,
        isDebugBuild: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let old = tmpPath(bundleID: bundleID, tag: tag, isDebugBuild: isDebugBuild, home: home)
        return resolve(bundleID: bundleID, tag: tag, isDebugBuild: isDebugBuild, home: home) == old ? nil : old
    }

    /// The pre-move path: `/tmp/cmux-…` for every build but release.
    private func tmpPath(bundleID: String?, tag: String?, isDebugBuild: Bool, home: URL) -> String {
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

    /// Returns the local control-socket paths on which another cmux build may be listening.
    ///
    /// The classic app uses `/tmp/cmux.sock`; cmux-next uses the channel and tagged paths
    /// resolved above. The directory scan is deliberately limited to `/tmp` and to cmux's
    /// own prefixes, so a stale or unrelated Unix socket is never treated as a peer without
    /// a successful `system.identify` response.
    public func peerSocketPaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let state = stateDirectory(home: home)
        var paths = Set([
            "/tmp/cmux.sock",
            "/tmp/cmux-nightly.sock",
            "/tmp/cmux-rc.sock",
            "/tmp/cmux-staging.sock",
            "/tmp/cmux-debug.sock",
            state + "/cmux.sock",
        ])
        for directory in ["/tmp", state] {
            for entry in (try? FileManager.checked.contentsOfDirectory(atPath: directory)) ?? []
            where ["cmux-debug", "cmux-nightly", "cmux-rc", "cmux-staging", "cmux-release"].contains(where: entry.hasPrefix)
                && entry.hasSuffix(".sock") {
                paths.insert(directory + "/" + entry)
            }
        }
        // A compatibility symlink names a socket the state folder already lists.
        return paths.filter { path in
            var info = stat()
            // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
            // `info`, a local.
            return unsafe blockingLstat(path, &info) != 0 || info.st_mode & S_IFMT != S_IFLNK
        }.sorted()
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
    /// Socket file permissions for this mode.
    var filePermissions: mode_t {
        0o600
    }
}
