import AppKit
import CmuxNextCompat
import Darwin
import Foundation

/// Opens this app's bundle again once this process has exited: Restart to Update for a build that
/// is already installed on disk, where Sparkle has no installer to run (``UpdaterService/installedBuild``).
/// Started only by the person's click.
enum InstalledBuildRelaunch {
    /// Starts the helper and quits through the normal quit path (``NSApplication/terminate(_:)``), which keeps every session.
    /// From a run-loop callout: `relaunchKeepSessions` calls this inside a main-actor Task (a `DemandTimer` fire),
    /// and a terminate there never quit (the quit's reply needs the main queue that Task holds).
    @MainActor static func relaunch(bundle: URL) -> Bool {
        guard start(bundle: bundle) else { return false }
        NSApplication.terminateFromRunLoop()
        return true
    }

    /// Waits for `$1` (this app's pid) to exit, at most `$2` ticks (a refused quit never leaves
    /// the helper behind), then opens the bundle `$0`. Any further arguments are `open` options:
    /// the running app's home (``RelaunchHome``), so an app in a custom home reopens in it.
    static let script = #"""
    n=0
    while /bin/kill -0 "$1" 2>/dev/null && [ "$n" -lt "$2" ]; do /bin/sleep 0.2; n=$((n+1)); done
    /bin/kill -0 "$1" 2>/dev/null && exit 0
    shift 2
    exec /usr/bin/open "$@" "$0"
    """#

    /// How long the helper waits for the quit: 5 ticks a second, two minutes.
    static let maxTicks = 600

    static func arguments(bundle: URL, pid: pid_t, openOptions: [String] = RelaunchHome.openArguments()) -> [String] {
        ["/bin/sh", "-c", script, bundle.path, String(pid), String(maxTicks)] + openOptions
    }

    /// Starts the helper; false when it could not start (the app then stays).
    static func start(bundle: URL) -> Bool {
        // main-actor-ok: one spawn of /bin/sh on the person's Restart click, right before the app quits.
        let process = Process()
        let args = arguments(bundle: bundle, pid: getpid())
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
