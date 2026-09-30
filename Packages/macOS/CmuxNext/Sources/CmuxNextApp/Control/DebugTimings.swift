import AppKit
import CmuxNextSettings
import CmuxNextTerminal
import Darwin
import os

/// `debug.timings`: main-thread spans of the paths the stall bench measures
/// (scripts/cmux-next/bench-stalls.py): launch phases, each palette open,
/// each terminal surface creation. `clear` drops the per-event lists (the
/// launch marks stay). Each span is also an Instruments signpost interval
/// (subsystem com.cmuxterm.app.next, category "stalls").
@MainActor
enum DebugTimings {
    static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")

    private static var launchMarks: [(name: String, ms: Double)] = []
    private static var paletteOpens: [(ms: Double, createdPanel: Bool)] = []
    private static var surfaces: [Double] = []
    private static let capacity = 256

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// Milliseconds since the process started (kernel start time).
    static var sinceProcessStart: Double {
        Date().timeIntervalSince(processStart) * 1_000
    }

    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    /// Records a launch mark (milliseconds since process start) once per name.
    static func markLaunch(_ name: String) {
        guard !launchMarks.contains(where: { $0.name == name }) else { return }
        launchMarks.append((name, sinceProcessStart))
        signposter.emitEvent("launch", "\(name, privacy: .public)")
    }

    /// Marks `name` when the current Core Animation transaction commits:
    /// the frame that carries this pass's changes reached the render server.
    static func markLaunchOnCommit(_ name: String) {
        CATransaction.setCompletionBlock { markLaunch(name) }
    }

    static func install() {
        TerminalTimings.onSurfaceCreated = { duration in
            let ms = milliseconds(duration)
            if surfaces.count < capacity { surfaces.append(ms) }
            markLaunch("first_terminal_surface_created")
        }
    }

    static func palettePresented(_ duration: Duration, createdPanel: Bool) {
        if paletteOpens.count < capacity { paletteOpens.append((milliseconds(duration), createdPanel)) }
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
        for mark in launchMarks { launch[mark.name] = round(mark.ms) }
        return [
            "launch_ms_since_process_start": .object(launch),
            "palette_opens": .array(paletteOpens.map { ["ms": round($0.ms), "created_panel": .bool($0.createdPanel)] }),
            "terminal_surfaces_ms": .array(surfaces.map(round)),
        ]
    }
}
