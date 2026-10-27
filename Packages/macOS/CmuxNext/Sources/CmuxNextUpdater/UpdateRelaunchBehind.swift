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
    /// The helper. It first looks up Sparkle's installer job and prints its pid (or nothing) on
    /// stdout: the app quits only once it read a pid, so the installer is known before the app
    /// ends (it waits for that exit to install). fd 3 is the read end of a pipe whose write end
    /// only the app holds: EOF means the app ended, a line means the app did not quit (the helper
    /// ends, opening nothing). Once the app ended, the helper waits for the installer's exit
    /// (`caffeinate -w`, the kernel's exit event; no polling), then `open -g` starts the bundle
    /// (the installed build, or the previous one Sparkle put back when the install failed) with
    /// ``reopenArgument``, so either build starts behind.
    public nonisolated static let script = #"""
    installer=$(/bin/launchctl list "$1" 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*"PID" = \([0-9][0-9]*\);$/\1/p')
    [ -n "$installer" ] || installer=$(/bin/launchctl print "system/$1" 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p')
    echo "$installer"
    exec 1>/dev/null
    IFS= read -r refused <&3
    [ -n "$refused" ] && exit 0
    /usr/bin/caffeinate -w "$installer" || exit 1
    exec /usr/bin/open -g "$0" --args "$2"
    """#

    /// How long the app waits for the helper's installer lookup before it gives up and stays.
    public nonisolated static let lookupTimeoutMilliseconds: Int32 = 5_000

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

    /// The helper's argv: `sh -c SCRIPT APP JOB REOPEN_ARGUMENT`.
    public nonisolated static func arguments(app: URL, installerJob: String) -> [String] {
        ["/bin/sh", "-c", script, app.path, installerJob, UpdateRelaunchFocus.reopenArgument]
    }

    private let arguments: [String]
    /// The running helper, from its start until the app ends or the quit is refused.
    private var helper: (pid: pid_t, writeEnd: Int32)?
    private var declined: (@MainActor () -> Void)?

    public init(app: URL, bundleIdentifier: String) {
        arguments = Self.arguments(app: app, installerJob: Self.installerJobLabel(bundleIdentifier: bundleIdentifier))
    }

    /// Starts the helper and, once it found Sparkle's installer, asks `willQuit` (which rechecks
    /// that the app still stays behind and runs the relaunch hooks) and quits; the installer is
    /// waiting for this exit. When `willQuit` says no (the user came into the app meanwhile), the
    /// helper stops and `inFront` runs (Sparkle relaunches, activating). `declined` runs instead
    /// when the helper cannot start or finds no installer (nothing ran, the app keeps running), or
    /// later from ``quitRefused()``: the update is staged again.
    public func start(willQuit: @escaping @MainActor () -> Bool, declined: @escaping @MainActor () -> Void,
                      inFront: @escaping @MainActor () -> Void) {
        let arguments = arguments
        // task-owner: one spawn and its lookup answer (off main: a fork and exec, then a bounded
        // read), then the quit; ends there.
        Task { @MainActor in
            let started = await Task.detached(priority: .userInitiated) { () -> (pid: pid_t, writeEnd: Int32, installer: Int32?)? in
                guard let helper = Self.spawn(arguments) else { return nil }
                let installer = Self.readInstaller(helper.stdout, timeoutMilliseconds: Self.lookupTimeoutMilliseconds)
                close(helper.stdout)
                return (helper.pid, helper.writeEnd, installer)
            }.value
            guard let started else { return declined() }
            guard started.installer != nil else {
                Self.stop(started.pid, started.writeEnd)
                return declined()
            }
            guard willQuit() else {
                Self.stop(started.pid, started.writeEnd)
                return inFront()
            }
            self.helper = (started.pid, started.writeEnd)
            self.declined = declined
            NSApplication.terminateFromRunLoop()
        }
    }

    /// The installer pid the helper printed, nil when it found none or did not answer in time.
    nonisolated static func readInstaller(_ fd: Int32, timeoutMilliseconds: Int32) -> Int32? {
        var line = [UInt8]()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutMilliseconds)))
        while !line.contains(0x0A) {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return nil }
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, Int32(left.components.seconds * 1_000 + left.components.attoseconds / 1_000_000_000_000_000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            line += buffer[0..<count]
        }
        let text = String(decoding: line.prefix { $0 != 0x0A }, as: UTF8.self)
        return Int32(text).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The quit was refused (the user kept the app at a quit dialog): the helper is told to stop,
    /// opening nothing, and the update is staged again. No-op once the helper is gone.
    public func quitRefused() {
        guard let helper else { return }
        self.helper = nil
        Self.stop(helper.pid, helper.writeEnd)
        let declined = declined
        self.declined = nil
        declined?()
    }

    /// Tells the helper the app does not quit, then reaps it off main (it ends on the line).
    nonisolated static func stop(_ pid: pid_t, _ writeEnd: Int32) {
        refuse(writeEnd)
        Task.detached(priority: .utility) { _ = waitpid(pid, nil, 0) }
    }

    /// Tells the helper the quit was refused (it ends, opening nothing), and closes the pipe.
    nonisolated static func refuse(_ writeEnd: Int32) {
        let line = Array("refused\n".utf8)
        _ = line.withUnsafeBufferPointer { write(writeEnd, $0.baseAddress, $0.count) }
        close(writeEnd)
    }

    /// Spawns the helper with the quit pipe's read end as its fd 3 and a second pipe as its
    /// stdout; returns its pid, the quit pipe's write end (close-on-exec, no SIGPIPE) and the
    /// stdout pipe's read end, or nil when the helper could not start.
    nonisolated static func spawn(_ arguments: [String]) -> (pid: pid_t, writeEnd: Int32, stdout: Int32)? {
        var ends: [Int32] = [-1, -1], out: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        guard pipe(&out) == 0 else {
            close(ends[0])
            close(ends[1])
            return nil
        }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        for fd in ends + out { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        defer {
            close(readEnd)
            close(out[1])
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        // dup2 onto another descriptor clears close-on-exec (dup2(3, 3) would not), so both
        // sources sit above the targets first.
        let source = fcntl(readEnd, F_DUPFD_CLOEXEC, 10), outSource = fcntl(out[1], F_DUPFD_CLOEXEC, 10)
        defer {
            if source >= 0 { close(source) }
            if outSource >= 0 { close(outSource) }
        }
        guard source >= 0, outSource >= 0 else {
            close(writeEnd)
            close(out[0])
            return nil
        }
        posix_spawn_file_actions_adddup2(&actions, outSource, 1)
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
            close(out[0])
            return nil
        }
        return (child, writeEnd, out[0])
    }
}

/// Runs `body` with `strings` as a NULL-terminated C string array (argv / envp).
nonisolated private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
}
