import CmuxNextCompat
import Darwin
import Foundation
import os

/// Starts this run's out-of-process watcher: `bin/cmux __app-watch` (cmux-tui
/// `app_watch.rs`, issue #22844, plans/cmux-next/crash-classes.md).
///
/// Crash-only recovery: the app does not try to go on after a crash or a hung
/// main thread; it ends in bounded time and comes back. Two things inside the
/// process cannot guarantee that: the crash deadline thread stops when a crash
/// reporter suspends every thread, and nothing in-process can safely end a
/// main thread that never returns. The watcher is a separate, much simpler
/// process in its own session that outlives the app. It reads one byte per
/// event from a pipe (`AppWatchChannel`: crash began, hang
/// began/ended, quit began), ends a crash that did not finish in
/// `crashGrace` or a hang that lasted `hangLimit`, records why in `run.watch`
/// (the next launch's notice names it), and relaunches the app after a crash
/// it saw or an ending it made. The relaunched app restores from the daemon
/// and the store like any launch. Force Quit and `kill -9` are never
/// relaunched.
///
/// Environment (diagnostics and tests): `CMUX_NEXT_APP_WATCH=0` starts no
/// watcher; `CMUX_NEXT_APP_WATCH_HANG_SECONDS` (0 = never end a hang) and
/// `CMUX_NEXT_APP_WATCH_CRASH_SECONDS` override the limits;
/// `CMUX_NEXT_APP_WATCH_RELAUNCH=0` ends without relaunching. An agent or
/// test launch (`CMUX_NEXT_NO_ACTIVATE=1`) never comes back by itself: it
/// is ended but not relaunched unless `CMUX_NEXT_APP_WATCH_RELAUNCH=1`.
enum AppWatcher {
    static let defaultHangLimit = 30
    static let defaultCrashGrace = 15
    /// How long the watcher has to report that it waits.
    static let readyLimitMilliseconds: Int32 = 3_000

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    /// Reaps the watcher if it ends while the app runs (it normally outlives the app).
    private static let reaper = Mutex<(any DispatchSourceProcess)?>(nil)

    /// The watcher's arguments for this run; nil when it is turned off.
    static func arguments(pid: Int32, executable: URL, markerFolder: URL, launchedAsRestart: Bool,
                          environment: [String: String]) -> [String]? {
        if environment["CMUX_NEXT_APP_WATCH"] == "0" { return nil }
        let hang = environment["CMUX_NEXT_APP_WATCH_HANG_SECONDS"].flatMap(Int.init).map { max($0, 0) } ?? defaultHangLimit
        let crash = environment["CMUX_NEXT_APP_WATCH_CRASH_SECONDS"].flatMap(Int.init).map { max($0, 1) } ?? defaultCrashGrace
        var arguments = ["__app-watch", "--pid", String(pid), "--exe", executable.path, "--marker-dir", markerFolder.path,
                         "--hang-limit", String(hang), "--crash-grace", String(crash)]
        if launchedAsRestart { arguments.append("--launched-as-restart") }
        let relaunch = environment["CMUX_NEXT_APP_WATCH_RELAUNCH"]
        if relaunch == "0" || (environment["CMUX_NEXT_NO_ACTIVATE"] == "1" && relaunch != "1") {
            arguments.append("--no-relaunch")
        }
        return arguments
    }

    /// Starts the watcher off the main thread. Call once, after the run
    /// marker's crash handlers are in place.
    static func start(markerFolder: URL, launchedAsRestart: Bool) {
        guard let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              let executable = Bundle.main.executableURL else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let arguments = arguments(pid: getpid(), executable: executable, markerFolder: markerFolder,
                                        launchedAsRestart: launchedAsRestart, environment: environment) else {
            logger.info("app watcher off (CMUX_NEXT_APP_WATCH=0)")
            return
        }
        let log = markerFolder.appending(path: "watch.log")
        Task.detached(priority: .utility) {  // task-owner: one-shot spawn; the watcher outlives the app on purpose
            spawn(cli: cli, arguments: arguments, log: log)
        }
    }

    private static func spawn(cli: URL, arguments: [String], log: URL) {
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            logger.error("app watcher not started: no bundled cmux")
            return
        }
        var events: [Int32] = [-1, -1]
        var ready: [Int32] = [-1, -1]
        guard pipe(&events) == 0 else { return }
        guard pipe(&ready) == 0 else {
            close(events[0]); close(events[1])
            return
        }
        // No other child the app starts meanwhile (a restored terminal, a helper) may inherit an end;
        // the watcher still gets its two through the spawn's dup2.
        for descriptor in events + ready { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        defer { close(ready[0]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            close(events[0]); close(events[1]); close(ready[1])
            return
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let configured = posix_spawn_file_actions_adddup2(&actions, events[0], STDIN_FILENO) == 0
            && posix_spawn_file_actions_adddup2(&actions, ready[1], STDOUT_FILENO) == 0
            && log.path.withCString({ path in
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            }) == 0
            && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)) == 0
        var pid: pid_t = 0
        let argv = [cli.path] + arguments
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let status: Int32 = configured ? withCStrings(argv) { argv in
            withCStrings(environment) { envp in posix_spawn(&pid, cli.path, &actions, &attributes, argv, envp) }
        } : -1
        close(events[0])
        close(ready[1])
        guard status == 0 else {
            close(events[1])
            logger.error("app watcher spawn failed status=\(status, privacy: .public)")
            return
        }
        reapWhenDone(pid)
        guard readLine(ready[0], limit: readyLimitMilliseconds) == "cmux-app-watch ready 1" else {
            // An older bundled cmux without the mode: end the child this call started, only while
            // it is not reaped yet (a reaped pid may belong to another process by now).
            reaper.withLock { source in
                if source != nil { kill(pid, SIGKILL) }
            }
            close(events[1])
            logger.error("app watcher pid \(pid, privacy: .public) did not report ready; not watched")
            return
        }
        AppWatchChannel.attach(events[1])
        logger.info("app watcher pid \(pid, privacy: .public) watches this run")
    }

    /// Reaps the watcher if it ends while the app runs (it normally outlives it).
    private static func reapWhenDone(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            // Reaped under the lock: until then the pid is a zombie that no other process can take,
            // so the ready-timeout kill below never reaches a reused pid.
            reaper.withLock { source in
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
                source?.cancel()
                source = nil
            }
        }
        reaper.withLock { $0 = source }
        source.resume()
    }

    /// One line from `descriptor` within `limit` ms; nil on timeout or EOF.
    private static func readLine(_ descriptor: Int32, limit: Int32) -> String? {
        var bytes: [UInt8] = []
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(limit) * 1_000_000
        while bytes.count < 256 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var poll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // concurrency-allow: detached spawn task, bounded by the ready deadline; never the main thread.
            let ready = Darwin.poll(&poll, 1, Int32((deadline - now) / 1_000_000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            var byte: UInt8 = 0
            // concurrency-allow: detached spawn task; poll said a byte is ready.
            guard read(descriptor, &byte, 1) == 1 else { return nil }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }

    /// A nil-terminated C string array for `body`; -1 when it cannot be built.
    private static func withCStrings(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) -> Int32 {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return body(base)
        }
    }
}
