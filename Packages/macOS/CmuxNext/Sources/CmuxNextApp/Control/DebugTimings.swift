import AppKit
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTerminal
import class CmuxNextDaemon.DaemonLaunchTimings
import Darwin
import os
import Synchronization

/// `debug.timings`: main-thread spans of the paths the stall bench measures
/// (scripts/cmux-next/bench-stalls.py): launch phases, each palette open,
/// each terminal surface creation. `clear` drops the per-event lists (the
/// launch marks stay). Each span is also an Instruments signpost interval
/// (subsystem com.cmuxterm.app.next, category "stalls").
@MainActor
enum DebugTimings {
    static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")

    /// Launch marks from any thread (the daemon start path runs off main).
    private nonisolated static let launchMarks = Mutex<[(name: String, ms: Double)]>([])
    private static var paletteOpens: [PaletteOpenTiming] = []
    private static var surfaces: [Double] = []
    private static let capacity = 256

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// Milliseconds since the process started (kernel start time).
    nonisolated static var sinceProcessStart: Double {
        Date().timeIntervalSince(processStart) * 1_000
    }

    private nonisolated static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    /// Records a launch mark (milliseconds since process start) once per
    /// name, from any thread.
    nonisolated static func markLaunch(_ name: String, at date: Date = Date()) {
        let ms = date.timeIntervalSince(processStart) * 1_000
        let first = launchMarks.withLock { marks in
            guard !marks.contains(where: { $0.name == name }) else { return false }
            marks.append((name, ms))
            return true
        }
        if first { LaunchMarkSink.shared.write(name: name, ms: ms) }
    }

    static func install() {
        DaemonLaunchTimings.shared.install { markLaunch($0, at: $1) }
        TerminalTimings.onSurfaceCreated = { duration in
            let ms = milliseconds(duration)
            if surfaces.count < capacity { surfaces.append(ms) }
            markLaunch("first_terminal_surface_created")
        }
    }

    static func palettePresented(_ timing: PaletteOpenTiming) {
        if paletteOpens.count < capacity { paletteOpens.append(timing) }
    }

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        let report = self.report
        if params["clear"]?.boolValue == true {
            paletteOpens.removeAll()
            surfaces.removeAll()
        }
        return report
    }

    private static var report: JSONValue {
        func round(_ ms: Double) -> JSONValue { .number((ms * 10).rounded() / 10) }
        var launch: [String: JSONValue] = [:]
        for mark in launchMarks.withLock({ $0 }) { launch[mark.name] = round(mark.ms) }
        return [
            "launch_ms_since_process_start": .object(launch),
            "palette_opens": .array(paletteOpens.map { open in
                ["ms": round(milliseconds(open.total)), "model_ms": round(milliseconds(open.model)),
                 "panel_ms": round(milliseconds(open.panel)), "present_ms": round(milliseconds(open.present)),
                 "commit_ms": round(milliseconds(open.commit)), "created_panel": .bool(open.createdPanel)]
            }),
            "terminal_surfaces_ms": .array(surfaces.map(round)),
            "ghostty_runtime_ms": .object(Dictionary(TerminalTimings.runtimePhases.map { ($0.name, round(milliseconds($0.duration))) },
                                                     uniquingKeysWith: { first, _ in first })),
        ]
    }
}
