import Darwin
public import Foundation

/// The socket of a session's daemon, remembered from the last connection,
/// so the next launch connects to a running daemon at once instead of first
/// spawning `cmux-tui server status` to find it. Stored per session name in
/// the app's defaults; only a path. It is a hint: `DaemonLauncher` uses it
/// only when it is a socket this user owns that accepts a connection, and
/// otherwise runs `server status` / `server ensure` as before.
public struct DaemonSocketMemory: Sendable {
    let defaults: @Sendable () -> UserDefaults

    public init(defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
        self.defaults = defaults
    }

    static func key(session: String) -> String { "cmuxNext.daemonSocket." + session }

    public func socket(session: String) -> String? {
        defaults().string(forKey: Self.key(session: session))
    }

    /// Records the socket the last handshake used (nil forgets it).
    public func record(_ path: String?, session: String) {
        let key = Self.key(session: session)
        guard defaults().string(forKey: key) != path else { return }
        defaults().set(path, forKey: key)
    }

    /// True when `path` is a Unix socket owned by this user that accepts a
    /// connection now. A stale file left by a killed daemon refuses at once.
    public static func acceptsConnections(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { return false }
        guard let transport = try? LineTransport(path: path) else { return false }
        transport.close()
        return true
    }
}
