import Darwin
import Foundation

/// Terminal host processes (one PTY each) that a daemon spawned: its
/// children running `cmux-tui __terminal-host`. Teardown checks that none
/// outlives the daemon, so test runs never leak PTYs (the Mac allows 511).
enum TerminalHosts {
    static func of(daemon pid: Int32) -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid), "-f", "__terminal-host"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) })
    }

    /// The daemon's host children that serve a terminal: those with a
    /// published discovery record under `state`. This leaves out the spare
    /// host (R81: one idle `__terminal-host` started ahead of the next new
    /// tab, with no PTY and no record until a new tab adopts it). Leak
    /// checks use `of(daemon:)`, which includes the spare.
    static func terminals(daemon pid: Int32, state: URL) -> Set<Int32> {
        of(daemon: pid).intersection(published(state: state))
    }

    /// Host pids named by the discovery records under `state`
    /// (`terminal-hosts-*/<terminal>.json`).
    static func published(state: URL) -> Set<Int32> {
        let files = FileManager.default
        guard let roots = try? files.contentsOfDirectory(at: state, includingPropertiesForKeys: nil) else { return [] }
        var pids = Set<Int32>()
        for root in roots where root.lastPathComponent.hasPrefix("terminal-hosts-") {
            for file in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (object["host_pid"] as? NSNumber)?.int32Value else { continue }
                pids.insert(pid)
            }
        }
        return pids
    }

    /// Waits for `pids` to exit and returns those still running. Each exit is
    /// a kernel event (a process source per pid), so the wait ends at the last
    /// exit; `hangGuard` only bounds a process that never exits. The daemon
    /// replies once each host acknowledged its end; the exit trails by a few
    /// milliseconds.
    static func awaitExit(_ pids: Set<Int32>, hangGuard: Duration = .seconds(30),
                          clock: any Clock<Duration> = ContinuousClock()) async -> Set<Int32> {
        guard !pids.isEmpty else { return [] }
        let (exits, sink) = AsyncStream.makeStream(of: Int32.self)
        let sources = pids.map { pid in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
            source.setEventHandler { sink.yield(pid) }
            source.activate()
            return source
        }
        defer { for source in sources { source.cancel() } }
        // A pid that ended (or is a zombie) before its source armed sends no event.
        for pid in pids.subtracting(alive(pids)) { sink.yield(pid) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var running = pids
                for await pid in exits {
                    running.remove(pid)
                    if running.isEmpty { return }
                }
            }
            group.addTask { try? await clock.sleep(for: hangGuard) }
            await group.next()
            group.cancelAll()
        }
        return alive(pids)
    }

    /// The subset of `pids` still running (zombies awaiting reaping count as gone).
    static func alive(_ pids: Set<Int32>) -> Set<Int32> {
        pids.filter(isRunning)
    }

    /// Whether `pid` is a process that has not exited. An exited host stays
    /// a zombie until the daemon reaps it, and the daemon reaps on its own
    /// schedule (later under load). `proc_pidinfo(PROC_PIDTBSDINFO)` fails
    /// with ESRCH for a zombie, so it cannot tell a zombie from a live
    /// process; `sysctl(KERN_PROC_PID)` still returns a zombie's `p_stat`.
    static func isRunning(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return kill(pid, 0) == 0 }
        return size > 0 && Int32(info.kp_proc.p_stat) != SZOMB
    }
}
