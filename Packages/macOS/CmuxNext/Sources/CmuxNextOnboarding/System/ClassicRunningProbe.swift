public import Foundation

/// Whether classic cmux is running now, so it may still save its session.
///
/// Classic writes a launch sentinel, `<state>/lifecycle/<bundle id>/running.sentinel`
/// (`<state>` is `~/.local/state/cmux`, or `$XDG_STATE_HOME/cmux`), when it
/// launches and removes it at the end of a clean quit (`GhosttyCrashBreadcrumb`
/// on classic's `main`). No sentinel means classic quit: the Sparkle update
/// relaunch starts cmux-next seconds after classic's quit save, and that save
/// migrates. A sentinel with a save older than ``quietSeconds`` is a classic
/// that crashed (it autosaves every 8 s while it runs). No process scan
/// (plans/cmux-next/pty-holder.md).
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
}
