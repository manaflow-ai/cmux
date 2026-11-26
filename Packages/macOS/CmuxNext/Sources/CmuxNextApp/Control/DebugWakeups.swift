import AppKit
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Darwin

/// `debug.wakeups`: who wakes this app and how much CPU the app, its
/// Chromium helpers and its cmux-tui daemon (with terminal hosts) use
/// (plans/cmux-next/idle-wakeups.md).
///
/// - `ledger`: every sanctioned primitive's wakeups per owner and reason,
///   with a rate over the last 10 complete seconds.
/// - `frame_schedulers`: each window's display link, its active clients and the links it made, and the app's
///   budgeted scheduler (``MainWorkScheduler``: the control queue, the daemon store drain).
/// - `processes`: cumulative CPU time and wakeups per process (diff two
///   calls for rates; `scripts/cmux-next/bench-idle.py` does), sampled on a
///   ``BackgroundWork`` system lane: every read is a system call (`proc_pid_rusage`,
///   `proc_listpids`, `proc_pidpath`, `KERN_PROCARGS2`), and a diagnostic never
///   runs one on the main thread.
/// - `main_run_loop` (with `run_loop: true`): the main run loop's description (`CFCopyDescription`):
///   every mode's timers with their interval and callout, sources and observers. An idle bench reads
///   the repeating timers from it to name what wakes the main thread outside the ledger.
enum DebugWakeups {
    static func report(_ params: [String: JSONValue], budgeted: FrameScheduler, work: BackgroundWork) async throws -> JSONValue {
        var object = mainActorPart(params, budgeted: budgeted)
        // A cancelled sample throws: an empty list would read as every process gone (bench-idle.py diffs two calls).
        let processes = try await work.run(.bestEffort, mayBlock: .system) { AppProcesses.sample() }
        object["processes"] = .array(processes.map(\.json))
        return .object(object)
    }

    @MainActor
    private static func mainActorPart(_ params: [String: JSONValue], budgeted: FrameScheduler) -> [String: JSONValue] {
        if params["reset"]?.boolValue == true { WakeupLedger.shared.reset() }
        let ledger = WakeupLedger.shared.snapshot()
        let all = FrameScheduler.all + [budgeted]
        let schedulers = all.map { scheduler -> JSONValue in
            [
                "name": .string(scheduler.name),
                "running": .bool(scheduler.isRunning),
                "has_link": .bool(scheduler.hasLink),
                "frames": JSONValue(Int(truncatingIfNeeded: scheduler.frames)),
                "links_made": JSONValue(Int(truncatingIfNeeded: scheduler.linksMade)),
                "active_clients": .array(scheduler.activeClients.map { .string($0) }),
            ]
        }
        var report: [String: JSONValue] = [
            "uptime_s": .number(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9),
            "total_per_second": .number(ledger.reduce(0) { $0 + $1.perSecond }),
            "ledger": .array(ledger.map { entry in
                [
                    "owner": .string(entry.owner), "reason": .string(entry.reason),
                    "count": JSONValue(Int(truncatingIfNeeded: entry.count)),
                    "per_second": .number(entry.perSecond),
                    "seconds_since_last": .number(entry.secondsSinceLast),
                ]
            }),
            "frame_schedulers": .array(schedulers),
            "active_frame_clients": .array(all.flatMap(\.activeClients).map { .string($0) }),
        ]
        if params["run_loop"]?.boolValue == true {
            report["main_run_loop"] = .string(CFCopyDescription(CFRunLoopGetMain()) as String)
        }
        return report
    }
}

/// This app, its Chromium helpers, and the bundled cmux-tui (daemon and
/// terminal hosts). Every function here makes system calls: call them off the
/// main thread (``BackgroundWork``, the busy watchdog's sampling queue).
nonisolated enum AppProcesses {
    struct Sample {
        var kind: String
        var usage: ProcessUsage

        var json: JSONValue {
            [
                "kind": .string(kind), "pid": JSONValue(Int(usage.pid)), "parent": JSONValue(Int(usage.parent)),
                "name": .string(usage.name),
                "cpu_ms": .number(Double(usage.cpuNanos) / 1e6),
                "wakeups": JSONValue(Int(truncatingIfNeeded: usage.wakeups)),
                "footprint_mb": .number(Double(usage.physFootprint) / 1_048_576),
                "uptime_ns": JSONValue(Int(truncatingIfNeeded: usage.uptimeNanos)),
            ]
        }
    }

    /// Chromium helper kinds, from the helper app's name.
    static func helperKind(_ path: String) -> String? {
        guard path.contains(" Helper") else { return nil }
        for kind in ["Renderer", "GPU", "Plugin", "Alerts"] where path.contains("(\(kind))") {
            return "cef-\(kind.lowercased())"
        }
        return "cef-helper"
    }

    /// Chromium helpers for the busy watchdog. Which tab a renderer serves
    /// is not known here (Chromium assigns renderers per site), so the label
    /// is the helper kind.
    static func chromiumHelpers() -> [BusyWatchdog.Helper] {
        ProcessUsage.children(of: getpid()).compactMap { pid in
            guard let path = ProcessUsage.path(of: pid), let kind = helperKind(path) else { return nil }
            return BusyWatchdog.Helper(pid: pid, label: kind)
        }
    }

    static func sample() -> [Sample] {
        let me = getpid()
        var out: [Sample] = []
        if let usage = ProcessUsage.sample(me) { out.append(Sample(kind: "app", usage: usage)) }
        for child in ProcessUsage.children(of: me) {
            guard let usage = ProcessUsage.sample(child), let kind = helperKind(usage.path) else { continue }
            out.append(Sample(kind: kind, usage: usage))
        }
        let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin").path + "/"
        let tui = ProcessUsage.processes(pathPrefix: bin).compactMap(ProcessUsage.sample)
        for usage in tui {
            // Terminal hosts run the same binary with `__terminal-host`.
            let isHost = ProcessUsage.arguments(of: usage.pid).contains { $0.hasPrefix("__terminal-host") }
            out.append(Sample(kind: isHost ? "terminal-host" : "daemon", usage: usage))
        }
        return out
    }
}
