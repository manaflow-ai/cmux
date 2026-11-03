import Darwin
import Foundation

/// The out-of-process half of the crash path (#22844): a watcher child ends
/// an app that is stuck in a crash path no in-process thread can end.
///
/// ``CrashDeadline`` ends a crash that blocks within 10 s, from a thread of
/// the app. Sentry suspends every other thread while it writes its report
/// (`sentrycrashmc_suspendEnvironment`), the deadline thread too; a Sentry
/// handler that then blocks froze the app at 0% CPU until Force Quit
/// (NIGHTLY 3950982952501 and 3951982493001, 2026-10-20).
///
/// At launch the app spawns `/bin/zsh` with ``script`` (posix_spawn with
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`: the child inherits only the read end of
/// one pipe as fd 3, and /dev/null as 0-2). The app keeps the only write
/// end. ``arm()`` (every crash path, next to the deadline's arm) writes one
/// byte with one async-signal-safe `write(2)`. The watcher then waits
/// ``seconds`` for the app's end, which it sees as EOF on the pipe (the
/// kernel closes the write end when the app ends, even as a zombie). If the
/// pipe is still open, the app is still alive: unless a debugger traces it,
/// the watcher samples it into the sample file (for the report) and sends
/// SIGKILL to that exact pid. `LaunchRecovery` then relaunches as for any
/// crash (the run marker is still there). A normal quit closes the pipe with
/// no byte, and the watcher exits at once; it never polls and wakes only for
/// a byte or the end.
///
/// The script needs only the system's zsh (`zsh/system`'s `sysread`, whose
/// statuses tell a timeout (4) from EOF (5); `/bin/sh` is bash 3.2 in POSIX
/// mode on macOS, or whatever `/private/var/select/sh` names, and its `read`
/// has no timeout status that tells EOF apart), `ps`, `sample` and `kill`: no
/// helper binary ships in the bundle. `zsh -f` (NO_RCS) reads no user file
/// (`~/.zshenv`, `~/.zshrc`, `ZDOTDIR`) and no `/etc/zprofile` or
/// `/etc/zshrc`; only `/etc/zshenv` cannot be skipped, which macOS does not
/// ship and only an administrator can add. Its environment is `PATH` alone.
struct CrashWatcher: Sendable {
    /// How long a crash path may run before the watcher ends the app: after
    /// the in-process deadline (``CrashDeadline/seconds``, 10 s), so that one
    /// acts first.
    static let defaultSeconds = 15

    /// The watcher, as `zsh -f -c script cmux-crash-watcher <pid> <sample file> <seconds>`.
    static let script = #"""
    zmodload zsh/system || exit 0
    pid=$1 out=$2 seconds=$3
    # fd 3: the read end of the app's pipe. A byte: a crash path began. EOF: the app ended.
    sysread -i 3 -s 1 byte || exit 0
    deadline=$(( SECONDS + seconds ))
    while (( SECONDS < deadline )); do
      sysread -i 3 -s 64 -t $(( deadline - SECONDS )) more
      case $? in
        0) ;;
        4) break ;;
        *) exit 0 ;;
      esac
    done
    # Still open: the app still runs. Never end a process a debugger traces (ps STAT X).
    [[ "$(/bin/ps -o stat= -p "$pid" 2>/dev/null)" == *X* ]] && exit 0
    /usr/bin/sample "$pid" 2 -mayDie -file "$out" >/dev/null 2>&1
    # The app may have ended during the sample: then its pid is not ours to signal.
    sysread -i 3 -s 64 -t 0 more
    (( $? == 5 )) && exit 0
    /bin/kill -KILL "$pid"
    """#

    /// Where the watcher writes its `sample` of the stuck app.
    let sampleFile: String
    /// Seconds from the first byte to the SIGKILL.
    let seconds: Int

    init(sampleFile: String, seconds: Int = CrashWatcher.defaultSeconds) {
        self.sampleFile = sampleFile
        self.seconds = seconds
    }

    /// A running watcher: its pid and the pipe's write end (``arm()`` writes to it).
    struct Spawned: Sendable {
        let pid: pid_t
        let writeEnd: Int32
    }

    enum SpawnError: Error, Equatable {
        case pipe(Int32)
        case spawn(Int32)
    }

    /// Spawns the watcher for `pid`. The returned write end is close-on-exec and never raises
    /// SIGPIPE (a write after the watcher ended returns EPIPE). Blocking (`posix_spawn`): call it
    /// off the main thread.
    func spawn(watching pid: pid_t) throws(SpawnError) -> Spawned {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw .pipe(errno) }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        // The window between pipe() and these calls is the only time a process spawned by another
        // thread without CLOEXEC_DEFAULT could inherit an end (macOS has no pipe2).
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
        // dup2 onto a different descriptor clears close-on-exec on fd 3; when the pipe's read end
        // is fd 3 itself, dup2(3, 3) would keep it, and the watcher would start with no fd 3.
        let source = fcntl(readEnd, F_DUPFD_CLOEXEC, 10)
        guard source >= 0 else {
            close(writeEnd)
            throw .pipe(errno)
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
        // Its own process group: a terminal's Ctrl-C or a group kill aimed at the app does not end the watcher first.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP))

        let arguments = ["/bin/zsh", "-f", "-c", Self.script, "cmux-crash-watcher", String(pid), sampleFile, String(seconds)]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        var child: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in posix_spawn(&child, "/bin/zsh", &actions, &attributes, argv, envp) }
        }
        guard status == 0 else {
            close(writeEnd)
            throw .spawn(status)
        }
        return Spawned(pid: child, writeEnd: writeEnd)
    }

    /// Starts the app's watcher once, off the main thread. Call at launch, after
    /// ``CrashDeadline/install()``; an ``arm()`` before the watcher runs does nothing (the deadline
    /// still acts).
    static func install(sampleFile: String) {
        let watcher = CrashWatcher(sampleFile: sampleFile)
        let app = getpid()
        DispatchQueue.global(qos: .utility).async {
            guard watcherDescriptor < 0, let spawned = try? watcher.spawn(watching: app) else { return }
            watcherDescriptor = spawned.writeEnd
        }
    }

    /// A crash path began: tells the watcher, which ends the app ``seconds`` later if it still
    /// runs. Async-signal-safe (one `write(2)`); does nothing before ``install(sampleFile:)``.
    static func arm() {
        let descriptor = watcherDescriptor
        guard descriptor >= 0 else { return }
        var byte: UInt8 = 0x63
        _ = write(descriptor, &byte, 1)
    }
}

/// Runs `body` with `strings` as a NULL-terminated C string array (argv / envp).
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
}

// Written once, off the main thread, before any crash path can read it in practice; a signal
// handler reads it, so a plain global (an Int32 store is atomic on arm64 and x86_64).
// crash-allow: one aligned Int32 written once at launch, then only read (signal-handler state).
nonisolated(unsafe) private var watcherDescriptor: Int32 = -1
