import AppKit
import CmuxNextCompat
public import Foundation

/// An automatic install reopens the app without activating it. Sparkle relaunches into an
/// installed update through LaunchServices (`NSWorkspace.openURL`), which makes the new process
/// frontmost before any of its code runs, so the relaunched app could only hand the front back
/// after a flash (about 360 ms). For an install nobody clicked, in an app the user is not in,
/// the app quits instead, Sparkle's prepared installer installs as it exits (with no relaunch of
/// its own), and this helper opens the bundle in the background (`open -g`, LaunchServices'
/// don't-switch launch), so the app never comes forward.
@MainActor public final class UpdateRelaunchBehind {
    /// The helper. fd 3 is the read end of a pipe whose write end only the app holds: EOF means
    /// the app ended, a line means the quit was refused (the helper ends, opening nothing). The
    /// installer job is looked up first, while the app still runs: Sparkle's installer is then
    /// waiting for the app's exit, so the lookup cannot miss an installer that is replacing the
    /// bundle. Once the app ended, the helper waits for that installer's exit (`caffeinate -w`,
    /// the kernel's exit event; no polling), then `open -g` starts the bundle: the installed
    /// build, or the previous one Sparkle put back when the install failed.
    public nonisolated static let script = #"""
    job() {
      p=$(/bin/launchctl list "$1" 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*"PID" = \([0-9][0-9]*\);$/\1/p')
      [ -n "$p" ] || p=$(/bin/launchctl print "system/$1" 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p')
      echo "$p"
    }
    installer=$(job "$1")
    IFS= read -r refused <&3
    [ -n "$refused" ] && exit 0
    [ -n "$installer" ] || installer=$(job "$1")
    [ -n "$installer" ] && /usr/bin/caffeinate -w "$installer"
    [ -f "$0/Contents/Info.plist" ] || exit 1
    exec /usr/bin/open -g "$0"
    """#

    /// The helper's whole environment. `open` hands its environment to the app it launches, so the
    /// helper never inherits this process's (a launch-time `CMUX_NEXT_NO_ACTIVATE`, a test socket,
    /// the shell's variables): the new build starts with what LaunchServices gives it, as
    /// Sparkle's relaunch does.
    public nonisolated static let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]

    /// The launchd job Sparkle submits for its installer (`<host bundle id>-sparkle-updater`,
    /// SUInstallerLauncher): in the user's domain, or the system domain for an install that
    /// needed authorization.
    public nonisolated static func installerJobLabel(bundleIdentifier: String) -> String {
        "\(bundleIdentifier)-sparkle-updater"
    }

    /// The helper's argv: `sh -c SCRIPT APP JOB`.
    public nonisolated static func arguments(app: URL, installerJob: String) -> [String] {
        ["/bin/sh", "-c", script, app.path, installerJob]
    }

    private let arguments: [String]
    /// The running helper, from its start until the app ends or the quit is refused.
    private var helper: (pid: pid_t, writeEnd: Int32)?
    private var declined: (@MainActor () -> Void)?

    public init(app: URL, bundleIdentifier: String) {
        arguments = Self.arguments(app: app, installerJob: Self.installerJobLabel(bundleIdentifier: bundleIdentifier))
    }

    /// Starts the helper, then runs `willQuit` (the relaunch hooks) and quits; Sparkle's installer
    /// is waiting for this exit. `declined` runs instead when the helper cannot start (nothing ran,
    /// the app keeps running), or later from ``quitRefused()``: the update is staged again.
    public func start(willQuit: @escaping @MainActor () -> Void, declined: @escaping @MainActor () -> Void) {
        let arguments = arguments
        // task-owner: one spawn (off main: posix_spawn is a fork and exec), then the quit; ends there.
        Task { @MainActor in
            guard let helper = await Task.detached(priority: .userInitiated, operation: { Self.spawn(arguments) }).value else {
                return declined()
            }
            self.helper = helper
            self.declined = declined
            willQuit()
            NSApplication.terminateFromRunLoop()
        }
    }

    /// The quit was refused (the user kept the app at a quit dialog): the helper is told to stop,
    /// opening nothing, and the update is staged again. No-op once the helper is gone.
    public func quitRefused() {
        guard let helper else { return }
        self.helper = nil
        Self.refuse(helper.writeEnd)
        // The helper ends on the line; reap it off main.
        Task.detached(priority: .utility) { _ = waitpid(helper.pid, nil, 0) }
        let declined = declined
        self.declined = nil
        declined?()
    }

    /// Tells the helper the quit was refused (it ends, opening nothing), and closes the pipe.
    nonisolated static func refuse(_ writeEnd: Int32) {
        let line = Array("refused\n".utf8)
        _ = line.withUnsafeBufferPointer { write(writeEnd, $0.baseAddress, $0.count) }
        close(writeEnd)
    }

    /// Spawns the helper with the pipe's read end as its fd 3; returns its pid and the write end
    /// (close-on-exec, no SIGPIPE), or nil when the helper could not start.
    nonisolated static func spawn(_ arguments: [String]) -> (pid: pid_t, writeEnd: Int32)? {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        defer { close(readEnd) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for target: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, target, "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        // dup2 onto another descriptor clears close-on-exec on fd 3 (dup2(3, 3) would not).
        let source = fcntl(readEnd, F_DUPFD_CLOEXEC, 10)
        guard source >= 0 else {
            close(writeEnd)
            return nil
        }
        defer { close(source) }
        posix_spawn_file_actions_adddup2(&actions, source, 3)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        // Its own process group, so a group signal aimed at the quitting app does not end it.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP))
        var child: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in posix_spawn(&child, arguments[0], &actions, &attributes, argv, envp) }
        }
        guard status == 0 else {
            close(writeEnd)
            return nil
        }
        return (child, writeEnd)
    }
}

/// Runs `body` with `strings` as a NULL-terminated C string array (argv / envp).
nonisolated private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
}
