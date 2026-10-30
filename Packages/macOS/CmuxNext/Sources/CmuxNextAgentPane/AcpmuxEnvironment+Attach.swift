public import CmuxNextCompat
public import Foundation

/// DEV builds only: `CMUX_NEXT_ACPMUX_ATTACH=<acpmux home>` (e.g. `~/.acpmux`, NIGHTLY's) makes
/// this app a client of the daemon of that home, so a DEV build reads the chats another app runs
/// (Leo, 2026-10-24: "also is it possible to do dev builds to like... read your existing app's
/// sessions? some sorta socket thing?").
///
/// The daemon stays its owner's: the app never starts, upgrades or hands it off
/// (``AcpmuxHost`` only looks, as a reconnect does), and its Quit never ends that daemon's agents
/// (`QuitAgents`). Allows are refused there (``AcpmuxServerPeer`` enrolls a person key only in a
/// daemon of this app's own executable). Off unless set, and honored only by a DEV identity
/// (`com.cmuxterm.app.debug*`: tagged DEV builds and NEXT DEV, a Release compile); stable, RC,
/// staging and NIGHTLY ignore it.
nonisolated extension AcpmuxEnvironment {
    static let attachKey = "CMUX_NEXT_ACPMUX_ATTACH"

    /// The bundle id prefix of the builds that may attach.
    static let attachBundlePrefix = "com.cmuxterm.app.debug"

    /// The home `environment` attaches `build` to: nil when unset, when `build` is not a DEV
    /// identity, or when the value is not an absolute path (a leading `~/` is `userHome`).
    public static func attachHome(build: BuildIdentity?,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let build, build.kind == .dev, build.bundleID?.hasPrefix(attachBundlePrefix) == true,
              let raw = environment[attachKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let path = raw == "~" ? userHome.path
            : raw.hasPrefix("~/") ? userHome.appendingPathComponent(String(raw.dropFirst(2))).path : raw
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// This environment pointed at the daemon of `home` (its socket by acpmux's rule) and marked
    /// ``isAttached``: no host starts, hands off or ends that daemon.
    public func attached(to home: URL, uid: UInt32 = getuid()) -> AcpmuxEnvironment {
        var attached = self
        attached.ownHome = ownHome ?? self.home
        attached.home = home
        attached.socketPath = Self.defaultSocketPath(home: home, uid: uid)
        attached.daemonArguments = []
        attached.childEnvironment["ACPMUX_HOME"] = home.path
        attached.childEnvironment["ACPMUX_SOCKET"] = attached.socketPath
        attached.isAttached = true
        return attached
    }
}
