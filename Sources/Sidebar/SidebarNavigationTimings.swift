import Foundation
import os

/// Structured latency lines for the navigation interactions, plus signpost
/// intervals for Instruments.
///
/// Env-gated by `CMUX_NAV_TIMINGS_LOG=<path>` and compiled in EVERY
/// configuration, not `#if DEBUG`: the Release build is the acceptance
/// environment for the performance budgets, so it has to be able to
/// self-report. With the variable unset every call is a single boolean
/// check. `scripts/harvest-nav-timings.py` turns the log into the table in
/// `PERFORMANCE.md`.
@MainActor
enum SidebarNavigationTimings {
    static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["CMUX_NAV_TIMINGS_LOG"] != nil

    private static let signposter = OSSignposter(
        subsystem: "com.cmuxterm.cmux",
        category: "navigation"
    )
    private static var pendingStartUptime: [String: TimeInterval] = [:]
    private static var pendingSignpost: [String: OSSignpostIntervalState] = [:]
    private static var tickSampleCounter = 0

    private static let logHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["CMUX_NAV_TIMINGS_LOG"] else {
            return nil
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    /// Starts (or restarts) an interaction interval.
    static func begin(_ interaction: String) {
        guard isEnabled else { return }
        pendingStartUptime[interaction] = ProcessInfo.processInfo.systemUptime
        let id = signposter.makeSignpostID()
        pendingSignpost[interaction] = signposter.beginInterval("nav", id: id)
    }

    /// Renames a pending interval (a switch discovered to be a cold mount).
    static func reclassify(_ from: String, as to: String) {
        guard isEnabled, let start = pendingStartUptime.removeValue(forKey: from) else { return }
        pendingStartUptime[to] = start
        if let interval = pendingSignpost.removeValue(forKey: from) {
            pendingSignpost[to] = interval
        }
    }

    /// Ends a pending interval and emits its line. No-op when none pending.
    static func end(_ interaction: String) {
        guard isEnabled, let start = pendingStartUptime.removeValue(forKey: interaction) else { return }
        if let interval = pendingSignpost.removeValue(forKey: interaction) {
            signposter.endInterval("nav", interval)
        }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        appendLine("nav.timing interaction=\(interaction) ms=\(String(format: "%.1f", ms))")
    }

    /// Drops a pending interval without emitting (an interaction that never
    /// completed, like a peek dismissed before reveal).
    static func cancel(_ interaction: String) {
        guard isEnabled else { return }
        pendingStartUptime.removeValue(forKey: interaction)
        if let interval = pendingSignpost.removeValue(forKey: interaction) {
            signposter.endInterval("nav", interval)
        }
    }

    /// Emits an intermediate delta for a pending switch without consuming
    /// it, so one Release pass bisects where the milliseconds go.
    static func lapPendingSwitch(_ label: String) {
        guard isEnabled else { return }
        for key in ["switch.cold", "switch.warm"] {
            guard let start = pendingStartUptime[key] else { continue }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            appendLine("nav.timing interaction=switch.lap.\(label) ms=\(String(format: "%.1f", ms))")
            return
        }
    }

    /// Ends whichever apply-driven interaction is pending. The sidebar's
    /// structural apply is the shared completion point for switch, create,
    /// and close; only the one that actually began emits.
    static func endAnyApplyDriven() {
        guard isEnabled else { return }
        for name in ["switch.cold", "switch.warm", "create", "close"] {
            end(name)
        }
    }

    /// Per-event cost sampling for high-frequency paths (reorder ticks).
    /// Emits one line in eight so a 120Hz stream does not turn the log into
    /// its own performance problem.
    static func recordSampledTick(_ interaction: String, startUptime: TimeInterval) {
        guard isEnabled else { return }
        tickSampleCounter += 1
        guard tickSampleCounter % 8 == 0 else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        appendLine("nav.timing interaction=\(interaction) ms=\(String(format: "%.2f", ms))")
    }

    private static func appendLine(_ line: String) {
        guard let logHandle, let data = (line + "\n").data(using: .utf8) else { return }
        logHandle.write(data)
    }
}
