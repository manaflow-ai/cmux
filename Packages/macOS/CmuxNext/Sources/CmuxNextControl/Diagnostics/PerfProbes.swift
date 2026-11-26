import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// The frame-timing and layout probes in every build, Release and NIGHTLY included, for
/// `cmux perf profile --frames`: Leo 2026-11-21, "we want our own bespoke profiler that's able to
/// identify these things and just be seeing like, okay, how would we maintain 120 hertz FPS?".
///
/// Off by default, and off again on every launch. `perf.probes.enable {"on": true}` turns them on
/// for at most `ttl_s` seconds (default 600, at most 3600); `{"on": false}` turns them off and
/// stops whatever they started. While off, every other `perf.*` method answers
/// `perf.probes_disabled` and does nothing.
///
/// Cost while off: no display link and no run-loop observer exist (the frame probe makes them at
/// its `start` only), the tab and workspace switch timers keep their one `isRecording` check per
/// switch, and the layout counters are one integer add per layout change (as
/// `LayoutRootView.layoutPasses` always was). The gate is one relaxed atomic load per `perf.*`
/// request; nothing reads it per frame.
///
/// The methods are `perf.*`, not `debug.*`: a Release router drops every `debug.*` registration
/// (``ControlRouter/Configuration/allowsDebugMethods``). Debug builds keep their `debug.*` methods,
/// ungated. Replies are timing numbers and counts only: `perf.hangs` has the watchdog's counters,
/// never its stack records (those stay in `debug.hangs`, Debug builds).
@MainActor
public final class PerfProbes {
    /// One probe the App owns: answers a request (`action`: start, stop, else a read); `{"action": "stop"}` ends its recording.
    public typealias Probe = @MainActor ([String: JSONValue]) -> JSONValue

    nonisolated public static let enableMethod = "perf.probes.enable"
    /// The methods the gate holds, in registration order after ``enableMethod``.
    nonisolated public static let gatedMethods = ["perf.frames", "perf.hangs", "perf.layout_counters", "perf.tab_switch", "perf.workspace_switch"]
    nonisolated public static let disabledCode = "perf.probes_disabled"
    nonisolated static let defaultTTL = 600
    nonisolated static let maximumTTL = 3_600

    public let gate = PerfProbeGate()
    private let watchdog: MainThreadWatchdog
    /// `perf.frames`, `perf.tab_switch`, `perf.workspace_switch`.
    private let recorders: [String: Probe]
    private let layoutCounters: Probe
    /// The recorders a `start` reached through this gate: turning it off stops those only, never a `debug.*` bench's.
    private var started: Set<String> = []
    private let expiry = DemandTimer(owner: "perf.probes.expiry")
    private var expiresAt: ContinuousClock.Instant?

    public init(watchdog: MainThreadWatchdog, frames: @escaping Probe, layoutCounters: @escaping Probe,
                tabSwitch: @escaping Probe, workspaceSwitch: @escaping Probe) {
        self.watchdog = watchdog
        self.layoutCounters = layoutCounters
        recorders = ["perf.frames": frames, "perf.tab_switch": tabSwitch, "perf.workspace_switch": workspaceSwitch]
    }

    public func methods() -> [ControlMethod] {
        var methods: [ControlMethod] = [.mainActor(Self.enableMethod) { [self] call in .value(try enable(call.params)) }]
        for name in Self.gatedMethods {
            if name == "perf.hangs" {
                // Off the main actor, as `debug.hangs`: it reads the watchdog's atomics, so it answers while the main thread stalls.
                methods.append(.snapshot(name) { [gate, watchdog] _ in try Self.hangs(gate: gate, watchdog: watchdog) })
            } else {
                methods.append(.mainActor(name) { [self] call in .value(try handle(name, call.params)) })
            }
        }
        return methods
    }

    /// `{"on": true, "ttl_s": 600}` turns the probes on until `ttl_s` passes; `{"on": false}` turns them off and stops
    /// what they started; no `on` reads the state. Answers `{"enabled", "expires_in_s"}`.
    public func enable(_ params: [String: JSONValue]) throws -> JSONValue {
        if let on = params["on"] {
            guard let on = on.boolValue else { throw ControlError.invalidParams("on must be true or false") }
            guard on else { disable(); return status }
            let ttl = try Self.ttl(params)
            gate.set(true)
            expiresAt = .now + .seconds(ttl)
            expiry.schedule(after: .seconds(ttl)) { @MainActor [weak self] in self?.disable() }
        }
        return status
    }

    public var status: JSONValue {
        let left = gate.isEnabled ? expiresAt.map { max(0, Double(($0 - .now).components.seconds)) } ?? 0 : 0
        return ["enabled": .bool(gate.isEnabled), "expires_in_s": .number(left)]
    }

    /// Off: the gate closes and every recording a `start` began through it stops now.
    public func disable() {
        gate.set(false)
        expiry.cancel()
        expiresAt = nil
        for name in started.sorted() { _ = recorders[name]?(["action": "stop"]) }
        started.removeAll()
    }

    /// A gated method other than `perf.hangs`: refused while off, else its probe's answer.
    public func handle(_ name: String, _ params: [String: JSONValue]) throws -> JSONValue {
        try gate.requireEnabled(for: name)
        if name == "perf.layout_counters" {
            guard case .object(var report) = layoutCounters(params) else { return .null }
            report["sources"] = nil // call sites stay out of the reply
            return .object(report)
        }
        guard let probe = recorders[name] else { throw ControlError.invalidParams("\(name) is not a perf probe") }
        if params["action"]?.stringValue == "start" { started.insert(name) }
        return probe(params)
    }

    nonisolated static func ttl(_ params: [String: JSONValue]) throws -> Int {
        guard let value = params["ttl_s"] else { return defaultTTL }
        guard let number = value.doubleValue, let seconds = Int(exactly: number), (1...maximumTTL).contains(seconds) else {
            throw ControlError.invalidParams("ttl_s must be a whole number of seconds from 1 to \(maximumTTL)")
        }
        return seconds
    }

    nonisolated static func disabledError(_ method: String) -> ControlError {
        ControlError(code: disabledCode,
                     message: "\(method): the perf probes are off; turn them on with \(enableMethod) {\"on\": true} (cmux perf profile --frames does)",
                     data: ["method": .string(method), "enable": .string(enableMethod)])
    }

    /// `debug.hangs`' counters without its records: stalls, long frames, gaps over a 120 Hz frame, main run-loop wakes.
    nonisolated public static func hangs(gate: PerfProbeGate, watchdog: MainThreadWatchdog) throws -> JSONValue {
        try gate.requireEnabled(for: "perf.hangs")
        let summary = watchdog.log.summary
        let longFrames = watchdog.longFrameStats
        let gaps = watchdog.gapStats
        return [
            "installed": .bool(watchdog.isRunning),
            "threshold_ms": .number(watchdog.configuration.threshold.fractionalMilliseconds),
            "count": JSONValue(summary.count),
            "busy_count": JSONValue(summary.busyCount),
            "max_ms": .number(summary.maxDuration.fractionalMilliseconds),
            "total_ms": .number(summary.totalDuration.fractionalMilliseconds),
            "long_frames": JSONValue(longFrames.count),
            "long_frame_max_ms": .number(longFrames.max.fractionalMilliseconds),
            "frames_over_8_3ms": JSONValue(gaps.over120HzFrame),
            "max_gap_ms": .number(gaps.max.fractionalMilliseconds),
            "main_wakes": JSONValue(Int(clamping: watchdog.mainRunLoopWakes)),
        ]
    }
}

/// Whether the perf probes are on: one relaxed atomic load, read once per `perf.*` request.
public final class PerfProbeGate: Sendable {
    private let enabled = Atomic<Bool>(false)

    public init() {}

    public var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    func set(_ on: Bool) { enabled.store(on, ordering: .relaxed) }

    /// Throws `perf.probes_disabled` for `method` while the probes are off.
    func requireEnabled(for method: String) throws {
        guard isEnabled else { throw PerfProbes.disabledError(method) }
    }
}
