public import Foundation

/// How the app starts one `cnx-hostd` (cnx-ios/rust/README.md lists its
/// variables). Pure: ``environment`` is what the child gets, and nothing of
/// the app's own environment leaks into it beyond `HOME`, `PATH` and `TMPDIR`.
public struct CnxHostLaunch: Sendable, Equatable {
    /// The bundled `Contents/Resources/bin/cnx-hostd`.
    public var executable: URL
    /// The cnx service (`https://cnx-ios-api-<env>.debussy.workers.dev`).
    public var baseURL: URL
    /// The Stack team, or `personal-<userId>` (PROTOCOL.md "Personal space").
    public var teamID: String
    /// The signed-in Stack user: only this user's phones are admitted.
    public var userID: String
    /// This Mac's persistent cnx device id (``CnxDeviceIdentity``).
    public var deviceID: String
    /// How phones list this Mac: the computer name.
    public var deviceName: String
    /// The app's own cmux-tui daemon socket.
    public var daemonSocket: String
    /// hostd's state directory (the app's, per bundle id).
    public var stateDirectory: URL
    /// Folders the phone's `file` service may read; empty denies every read.
    public var fileRoots: [String]
    /// Stack project and publishable key, for hostd's own token checks.
    public var stackProjectID: String

    public init(executable: URL, baseURL: URL, teamID: String, userID: String, deviceID: String, deviceName: String,
                daemonSocket: String, stateDirectory: URL, fileRoots: [String], stackProjectID: String) {
        self.executable = executable
        self.baseURL = baseURL
        self.teamID = teamID
        self.userID = userID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.daemonSocket = daemonSocket
        self.stateDirectory = stateDirectory
        self.fileRoots = fileRoots
        self.stackProjectID = stackProjectID
    }

    /// The team hostd joins: the selected Stack team, else the personal space.
    public static func teamID(selected: String?, userID: String) -> String {
        if let selected, !selected.isEmpty { return selected }
        return "personal-\(userID)"
    }

    /// The child's whole environment. `inherited` supplies only `HOME`, `PATH` and `TMPDIR`.
    public func environment(inherited: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "PATH", "TMPDIR"] { environment[key] = inherited[key] }
        let socket = URL(fileURLWithPath: daemonSocket)
        var session = socket.lastPathComponent
        if session.hasSuffix(".sock") { session.removeLast(5) }
        environment.merge([
            "CNX_CONTROL": "stdio",
            "CNX_BASE_URL": baseURL.absoluteString,
            "CNX_TEAM_ID": teamID,
            "CNX_OWNER_USER_ID": userID,
            "CNX_DEVICE_ID": deviceID,
            "CNX_DEVICE_NAME": deviceName,
            "CNX_STATE_DIR": stateDirectory.path,
            "CNX_TUI_SOCKET": daemonSocket,
            "CNX_TUI_SOCKET_DIR": socket.deletingLastPathComponent().path,
            "CNX_TUI_SESSION": session,
            "CNX_FILE_ROOTS": fileRoots.joined(separator: ":"),
            "CNX_STACK_PROJECT_ID": stackProjectID,
            // Tailscale addresses are the user's own overlay, not a path a phone
            // outside it can use; run-host.sh excludes them the same way.
            "CNX_EXCLUDE_CGNAT": "1",
            "NO_COLOR": "1",
        ]) { $1 }
        return environment
    }

    /// The control line that hands hostd an access token (never logged).
    public static func tokenLine(_ token: String) -> Data {
        line(["type": "token", "token": token])
    }

    /// The control line that tells hostd where the app's acpmux listens.
    public static func acpmuxLine(url: URL, token: String) -> Data {
        line(["type": "acpmux", "url": url.absoluteString, "token": token])
    }

    static func line(_ object: [String: String]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
