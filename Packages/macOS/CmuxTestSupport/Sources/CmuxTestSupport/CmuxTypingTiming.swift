#if DEBUG
public import AppKit
internal import CMUXDebugLog

/// DEBUG typing-latency probe: timestamps and logs the cost of each keystroke
/// path through the terminal and browser surfaces.
///
/// This is a faithful lift of the former app-target `CmuxTypingTiming` enum. It
/// is a stateless, caseless-enum static API on purpose: it is invoked from ~50
/// call sites on the typing hot path across `GhosttyTerminalView`,
/// `BrowserPanelView`, `CmuxWebView`, and `AppDelegate` (`start()` / `logEventDelay`
/// / `logDuration` / `logBreakdown`), and threading an instance through every one
/// of those latency-critical sites is out of scope for this byte-identical lift.
/// The only mutable coupling it had, the former
/// `CmuxMainThreadTurnProfiler.shared` it forwarded `logDuration` measurements to,
/// is replaced by ``turnProfiler``, a composition-root-installed reference to the
/// one injected ``MainThreadTurnProfiling`` instance, so the lift carries no
/// `static let shared` singleton.
///
/// All thresholds, environment/Defaults keys (`CMUX_TYPING_TIMING_LOGS`,
/// `CMUX_KEY_LATENCY_PROBE`, `cmuxTypingTimingLogs`, `cmuxKeyLatencyProbe`), log
/// prefixes (`typing.delay` / `typing.timing` / `typing.phase`), and field
/// formatting are frozen and identical to the original.
///
/// Isolation: not actor-isolated. The probe is read from the main thread on the
/// typing path; ``turnProfiler`` is installed once at launch on the main actor
/// before any keystroke can be processed and only read thereafter.
// Faithful byte-identical lift of the app-target `CmuxTypingTiming` probe,
// invoked as `CmuxTypingTiming.start()` / `logDuration` at ~50 typing-hot-path
// call sites across GhosttyTerminalView/BrowserPanelView/CmuxWebView/AppDelegate.
// It carries no per-instance state (config + formatting + one composition-root-
// installed `turnProfiler` forwarder); converting it to an injected instance is a
// separate, latency-sensitive slice that must thread an instance through every
// keystroke site and prove per-path latency, out of scope for this byte-identical
// move.
// lint:allow namespace-type — stateless typing probe; instance conversion is a follow-up latency slice (see note above)
public enum CmuxTypingTiming {
    /// The injected turn profiler that ``logDuration(path:startedAt:event:extra:)``
    /// forwards each measured span to. Installed once by the app's composition
    /// root immediately after constructing the profiler, replacing the former
    /// `CmuxMainThreadTurnProfiler.shared` singleton. `nonisolated(unsafe)` is
    /// sound here: it is written exactly once at launch on the main actor before
    /// any keystroke is processed, and read only on the main thread thereafter.
    nonisolated(unsafe) public static var turnProfiler: (any MainThreadTurnProfiling)?

    public static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_TYPING_TIMING_LOGS"] == "1" || environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "cmuxTypingTimingLogs") || defaults.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    public static let isVerboseProbeEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    private static let delayLogThresholdMs: Double = 6.0
    private static let durationLogThresholdMs: Double = 1.0

    @inline(__always)
    public static func start() -> TimeInterval? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.systemUptime
    }

    @inline(__always)
    public static func logEventDelay(path: String, event: NSEvent) {
        guard isEnabled else { return }
        guard event.timestamp > 0 else { return }
        let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        guard shouldLog(delayMs: delayMs, elapsedMs: nil) else { return }
        logDebugEvent("typing.delay path=\(path) delayMs=\(format(delayMs)) \(eventFields(event))")
    }

    @inline(__always)
    public static func logDuration(path: String, startedAt: TimeInterval?, event: NSEvent? = nil, extra: String? = nil) {
        turnProfiler?.endMeasure(path, startedAt: startedAt)
        guard let startedAt else { return }
        let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        guard shouldLog(delayMs: delayMs, elapsedMs: elapsedMs) else { return }
        var line = "typing.timing path=\(path) elapsedMs=\(format(elapsedMs))"
        if let event {
            line += " \(eventFields(event))"
            if let delayMs {
                line += " delayMs=\(format(delayMs))"
            }
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        logDebugEvent(line)
    }

    @inline(__always)
    public static func logBreakdown(
        path: String,
        totalMs: Double,
        event: NSEvent? = nil,
        thresholdMs: Double = 2.0,
        parts: [(String, Double)],
        extra: String? = nil
    ) {
        guard isEnabled else { return }
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        let hasSlowPart = parts.contains { $0.1 >= thresholdMs }
        guard isVerboseProbeEnabled || totalMs >= thresholdMs || hasSlowPart || (delayMs ?? 0) >= delayLogThresholdMs else {
            return
        }
        var line = "typing.phase path=\(path) totalMs=\(format(totalMs))"
        if let event {
            line += " \(eventFields(event))"
        }
        if let delayMs {
            line += " delayMs=\(format(delayMs))"
        }
        for (name, value) in parts where isVerboseProbeEnabled || value >= 0.05 {
            line += " \(name)=\(format(value))"
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        logDebugEvent(line)
    }

    @inline(__always)
    private static func eventFields(_ event: NSEvent) -> String {
        "eventType=\(event.type.rawValue) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat ? 1 : 0)"
    }

    @inline(__always)
    private static func shouldLog(delayMs: Double?, elapsedMs: Double?) -> Bool {
        if isVerboseProbeEnabled {
            return true
        }
        if let delayMs, delayMs >= delayLogThresholdMs {
            return true
        }
        if let elapsedMs, elapsedMs >= durationLogThresholdMs {
            return true
        }
        return false
    }

    @inline(__always)
    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
#endif
