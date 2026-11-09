import Darwin
public import Foundation

/// Whether classic cmux is running now, so it may still save its session.
///
/// Classic writes a launch sentinel, `<state>/lifecycle/<bundle id>/running.sentinel`
/// (`<state>` is `~/.local/state/cmux`, or `$XDG_STATE_HOME/cmux`), when it
/// launches and removes it at the end of a clean quit (`GhosttyCrashBreadcrumb`
/// on classic's `main`). No sentinel means classic quit: the Sparkle update
/// relaunch starts cmux-next seconds after classic's quit save, and that save
/// migrates. A sentinel with a save older than ``quietSeconds`` is a classic
/// that crashed (it autosaves every 8 s while it runs). Classic builds older
/// than the sentinel write none, so the app also asks whether the lock classic
/// holds beside its control socket is taken (``lockPaths(channel:home:)``,
/// ``isLockHeld(_:)``). cmux-next listens on the same socket names but holds no
/// such lock. No process scan (plans/cmux-next/pty-holder.md).
///
/// ```swift
/// let probe = ClassicRunningProbe(stateRoot: ClassicRunningProbe.defaultStateRoot(home: home, environment: environment))
/// probe.isRunning(source, now: Date().timeIntervalSince1970)
/// ```
public nonisolated struct ClassicRunningProbe: Sendable {
    /// How long after its last save a classic that left its sentinel still counts as running.
    public static let quietSeconds: Double = 90

    /// Classic's state folder, holding `lifecycle/`.
    public let stateRoot: URL

    /// - Parameter stateRoot: classic's state folder (``defaultStateRoot(home:environment:)`` in the app).
    public init(stateRoot: URL) {
        self.stateRoot = stateRoot
    }

    /// Classic's state folder: `$XDG_STATE_HOME/cmux` when set, else `<home>/.local/state/cmux`.
    public static func defaultStateRoot(home: URL, environment: [String: String]) -> URL {
        if let xdg = environment["XDG_STATE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("cmux", isDirectory: true)
        }
        return home.appendingPathComponent(".local/state/cmux", isDirectory: true)
    }

    /// The sentinel classic of `channel` (a bundle id) keeps while it runs.
    public func sentinel(channel: String) -> URL {
        stateRoot.appendingPathComponent("lifecycle", isDirectory: true)
            .appendingPathComponent(channel, isDirectory: true)
            .appendingPathComponent("running.sentinel", isDirectory: false)
    }

    /// Whether the classic that wrote `source` is running now (`now` in seconds since 1970).
    public func isRunning(_ source: ClassicMigrationSource, now: Double) -> Bool {
        FileManager.default.fileExists(atPath: sentinel(channel: source.bundleID).path) && now - source.modifiedAt < Self.quietSeconds
    }

    /// Whether the classic app that saves `source` is open and may still save, on this Mac: it holds the lock beside
    /// its control socket (``lockPaths(channel:home:)``; `lockHeld` answers for a path, nil asks ``isLockHeld(_:)``),
    /// or its launch sentinel under `stateRoot` (nil: ``defaultStateRoot(home:environment:)``) and a recent save say so.
    @MainActor
    public static func isOpen(_ source: ClassicMigrationSource?, lockHeld: (@MainActor (String) -> Bool)? = nil, stateRoot: URL? = nil) -> Bool {
        guard let source else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if lockPaths(channel: source.bundleID, home: home).contains(where: { lockHeld?($0) ?? isLockHeld($0) }) { return true }
        let root = stateRoot ?? defaultStateRoot(home: home, environment: ProcessInfo.processInfo.environment)
        return ClassicRunningProbe(stateRoot: root).isRunning(source, now: Date().timeIntervalSince1970)
    }

    /// The lock files classic of `channel` (a bundle id) holds while it listens:
    /// `<socket>.lock` beside `~/.local/state/cmux/cmux[-<channel>].sock`, then
    /// beside the `/tmp` one. cmux-next uses the same socket names
    /// (`ControlSocketPath`) but never takes these locks.
    public static func lockPaths(channel: String, home: URL) -> [String] {
        let suffix = ["com.cmuxterm.app.nightly": "-nightly", "com.cmuxterm.app.rc": "-rc",
                      "com.cmuxterm.app.staging": "-staging"][channel] ?? ""
        let name = "cmux\(suffix).sock.lock"
        return [home.appendingPathComponent(".local/state/cmux/\(name)").path, "/tmp/\(name)"]
    }

    /// Whether a process holds the `flock` on `path`, asked without blocking.
    /// A missing file, one another user owns, or a free lock is not held; a
    /// free lock is taken shared for an instant and let go at once.
    public static func isLockHeld(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { return false }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
