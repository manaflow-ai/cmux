import AppKit
import CmuxNextCompat
import CmuxNextWakeups
public import Foundation

/// An automatic install reopens the app without activating it. Sparkle relaunches into an
/// installed update through LaunchServices (`NSWorkspace.openURL`), which makes the new process
/// frontmost before any of its code runs, so the relaunched app could only hand the front back
/// after a flash (about 360 ms). For an install nobody clicked, in an app the user is not in,
/// the app quits instead, Sparkle's prepared installer installs as it exits (with no relaunch of
/// its own), and this helper opens the new build in the background (`open -g`, LaunchServices'
/// don't-switch launch), so the app never comes forward.
public nonisolated enum UpdateRelaunchBehind {
    /// The launchd job Sparkle submits for its installer (`<host bundle id>-sparkle-updater`,
    /// SUInstallerLauncher), in the user's domain.
    public static func installerJobLabel(bundleIdentifier: String) -> String {
        "\(bundleIdentifier)-sparkle-updater"
    }

    /// The helper that reopens `app` behind once `pid` has exited and Sparkle's installer is
    /// done: `caffeinate -w` waits on the kernel's exit event of the app, then of the installer
    /// job's process when it still runs (no polling), then `open -g` starts the installed build
    /// without activating it.
    public static func command(pid: Int32, app: URL, installerJob: String) -> [String] {
        let script = #"""
        /usr/bin/caffeinate -w "$1"
        installer=$(/bin/launchctl list "$2" 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*"PID" = \([0-9][0-9]*\);$/\1/p')
        [ -n "$installer" ] && /usr/bin/caffeinate -w "$installer"
        exec /usr/bin/open -g "$0"
        """#
        return ["/bin/sh", "-c", script, app.path, String(pid), installerJob]
    }

    /// Starts the helper for this process and bundle, then quits (the relaunch hook already
    /// recorded "keep sessions"). Sparkle's installer is waiting for this exit. When the helper
    /// cannot start, `otherwise` runs instead (Sparkle installs and relaunches as before).
    @MainActor public static func afterExit(_ app: URL, otherwise: @escaping @MainActor () -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let command = command(pid: ProcessInfo.processInfo.processIdentifier, app: app,
                              installerJob: installerJobLabel(bundleIdentifier: bundleID))
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command[0])
        helper.arguments = Array(command.dropFirst())
        // task-owner: one spawn, then the quit; ends with the app.
        Task { @MainActor in
            do {
                try await ProcessLauncher(label: "com.cmuxterm.next.relaunch", priority: .userBlocking).launched(helper)
            } catch {
                return otherwise()
            }
            NSApplication.terminateFromRunLoop()
        }
    }
}
