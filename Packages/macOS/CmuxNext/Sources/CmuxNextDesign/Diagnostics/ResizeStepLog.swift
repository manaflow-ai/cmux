import CmuxNextCompat
import CoreFoundation
import Foundation
import os

/// ``ResizeStepTimes``' steps and the unified log they write while someone streams its debug messages (subsystem
/// `com.cmuxterm.app.next`, category `live-resize`), in every build, Release too:
///
/// ```sh
/// log stream --level debug --style ndjson \
///   --predicate 'subsystem == "com.cmuxterm.app.next" AND category == "live-resize"'
/// ```
///
/// Each line reads `<kind> step=<n> <phase> ms=<ms>[ detail]`:
/// - the step's phases (`set_frame`, `tick`, `root_super_layout`, `pane_layout`, `pane_content.<view>`, ...);
/// - `input_age` / `input_wait`: how long the newest and the oldest pointer event the step shows waited for it;
/// - `step_precommit` (just before Core Animation's commit observer) and `step_commit` (just after it, with the step's
///   line count and the time its own lines took, `log_us`); `step_cut` when the next step began first;
/// - `gesture` at a gesture's first step, with the in-tree pages mode it runs in (`in_tree=on|off|...`, `source=`);
/// - `turn`: every main run-loop turn's busy time while a gesture is on (a step in the last 250 ms), `stepped=1` for the
///   turn of a step: the other turns are the work between steps (Chromium's tasks, timers);
/// - facts reported later for a step (``ResizeStepTimes/note(_:ms:step:detail:)``: the resize fence's outcome).
@MainActor
enum ResizeStepLog {
    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "live-resize")

    /// Someone streams the log's debug messages (tests force it: ``streamingOverride``).
    static var isStreaming: Bool { streamingOverride ?? logger.isEnabled(type: .debug) }

    /// Tests only: forces ``isStreaming``.
    static var streamingOverride: Bool?

    /// `CMUX_NEXT_STEP_LOG=lean` (a bench knob): only the lines the bench's tools read for a step's time, its turn, its
    /// input and its fence (``leanPhases``), not each pane's and page window's part. A recorded drag pays less of the
    /// log's own cost: 69 to 80 lines a window step, 1.3 to 1.7 ms of it (`log_us`, 2026-11-27).
    nonisolated static let lean = ProcessInfo.processInfo.environment["CMUX_NEXT_STEP_LOG"] == "lean"

    /// Tests only: forces ``lean``.
    static var leanOverride: Bool?

    /// The phases a lean log keeps.
    static let leanPhases: Set<String> = [
        "turn", "event", "input_age", "input_wait", "tick", "step_precommit", "step_commit", "set_frame", "step_cut",
        "fence_open", "fence_released", "fence_page", "gesture", "cef_pump", "cef_pump_end",
    ]

    /// Whether the log writes `phase`'s lines: every phase, or a lean log's own (``lean``).
    static func keeps(_ phase: String) -> Bool { true }

    /// The step being timed: from its start until its run-loop turn has committed (``committed(_:)``).
    struct Step {
        let kind: ResizeStepTimes.StepKind
        let id: UInt64
        let start: UInt64
        /// The lines written in this step and the time they took (the logging's own cost).
        var lines = 0
        var logNanos: UInt64 = 0
        var precommitted = false
    }

    static var step: Step?
    private static var steps: UInt64 = 0
    private static var lastKind: ResizeStepTimes.StepKind = .window
    private static var lastStepAt: UInt64 = 0
    private static var turnStepped = false
    /// A divider's pointer events since its last step (`NSEvent.timestamp`, uptime seconds): the oldest and the newest.
    private static var pendingInput: (oldest: TimeInterval, newest: TimeInterval)?
    /// The main run loop's runs, innermost last: when each one's current turn began (nil while it sleeps, or while a
    /// run nested in it has the thread).
    private static var runs: [UInt64?] = []
    private static var observers: [MainRunLoopObserver] = []
    /// A gesture is on while its last step began this recently: its turns are logged.
    private static let gestureNanos: UInt64 = 250_000_000

    static func begin(_ kind: ResizeStepTimes.StepKind, input: TimeInterval?) -> UInt64 {
        if step != nil { end("step_cut") }
        installObservers()
        steps &+= 1
        let begun = DispatchTime.now().uptimeNanoseconds
        let newGesture = begun &- lastStepAt >= gestureNanos
        step = Step(kind: kind, id: steps, start: begun)
        if newGesture {
            // The mode this gesture runs in, from the app itself (a harness checks it rather than infer it).
            let pages = InTreePages.shared
            write(kind, "gesture", 0, detail: " in_tree=\(pages.status.replacingOccurrences(of: " ", with: "_")) source=\(pages.source)")
        }
        lastKind = kind
        lastStepAt = begun
        turnStepped = true
        let now = ProcessInfo.processInfo.systemUptime
        if let input { write(kind, "input_age", (now - input) * 1_000) }
        if kind == .divider, let pending = pendingInput {
            write(kind, "input_age", (now - pending.newest) * 1_000)
            write(kind, "input_wait", (now - pending.oldest) * 1_000)
        }
        pendingInput = nil
        return begun
    }

    static func noteInput(_ timestamp: TimeInterval) {
        pendingInput = (pendingInput?.oldest ?? timestamp, timestamp)
    }

    /// One debug-level line, while the log streams; its own time is added to the open step's `log_us`. `step` defaults
    /// to the open step, else the last one.
    static func write(_ kind: ResizeStepTimes.StepKind, _ phase: String, _ ms: Double, step id: UInt64? = nil, detail: String = "") {
        guard isStreaming else { return }
        let begun = DispatchTime.now().uptimeNanoseconds
        let number = id ?? step?.id ?? steps
        logger.debug("\(kind.rawValue, privacy: .public) step=\(number, privacy: .public) \(phase, privacy: .public) ms=\(ms, format: .fixed(precision: 3), privacy: .public)\(detail, privacy: .public)")
        let spent = DispatchTime.now().uptimeNanoseconds &- begun
        step?.lines += 1
        step?.logNanos &+= spent
    }

    /// Ends the open step under `phase`: the time since its start, its line count and the log's own cost.
    static func end(_ phase: String) {
        guard let open = step else { return }
        step = nil
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- open.start) / 1_000_000
        ResizeStepTimes.keep(open.kind, phase, ms)
        let logMicros = Double(open.logNanos) / 1_000
        write(open.kind, phase, ms, step: open.id, detail: String(format: " lines=%ld log_us=%.1f", open.lines, logMicros))
    }

    /// Before Core Animation's commit observer: the step's work up to the commit (its layout and display passes).
    static func precommit() {
        guard let open = step, !open.precommitted else { return }
        step?.precommitted = true
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- open.start) / 1_000_000
        ResizeStepTimes.keep(open.kind, "step_precommit", ms)
        write(open.kind, "step_precommit", ms)
    }

    /// After Core Animation's commit (before waiting, or as a run exits): the step ends, and the turn's busy time is
    /// logged during a gesture. With nobody streaming any more (Release), the observers go.
    static func committed(_ activity: CFRunLoopActivity) {
        end("step_commit")
        let now = DispatchTime.now().uptimeNanoseconds
        if let begun = runs.last ?? nil {
            if now &- lastStepAt < gestureNanos {
                write(lastKind, "turn", Double(now &- begun) / 1_000_000, step: steps, detail: turnStepped ? " stepped=1" : " stepped=0")
            }
            turnStepped = false
        }
        if activity == .exit {
            if !runs.isEmpty { runs.removeLast() }
            // The run this one was nested in has the thread again.
            if !runs.isEmpty { runs[runs.count - 1] = now }
        } else if !runs.isEmpty {
            runs[runs.count - 1] = nil
        }
        if !ResizeStepTimes.isRecording { removeObservers() }
    }

    /// A run starts or wakes: its turn begins. A nested run's start ends its outer run's turn for now.
    static func turnBegan(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        if activity == .entry {
            if let outer = runs.last ?? nil, now &- lastStepAt < gestureNanos {
                write(lastKind, "turn", Double(now &- outer) / 1_000_000, step: steps, detail: turnStepped ? " stepped=1 nested=1" : " stepped=0 nested=1")
                turnStepped = false
            }
            if !runs.isEmpty { runs[runs.count - 1] = nil }
            runs.append(now)
        } else if runs.isEmpty {
            runs.append(now)
        } else {
            runs[runs.count - 1] = now
        }
    }

    /// The step's marks on the main run loop: a run's turn beginning (first of all), just before Core Animation's commit
    /// observer (order 2,000,000) and just after it. Installed at the first step; removed when a Release build stops
    /// being streamed.
    private static func installObservers() {
        guard observers.isEmpty else { return }
        observers = [
            MainRunLoopObserver(activities: [.entry, .afterWaiting], order: CFIndex.min + 1) { turnBegan($0) },
            MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: 1_999_999) { _ in precommit() },
            MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: 2_000_100, drawsNothingAfterCommit: true) {
                committed($0)
            },
        ]
    }

    private static func removeObservers() {
        for observer in observers { observer.invalidate() }
        observers.removeAll()
        runs.removeAll()
    }

    /// Tests only: no step open, no observers.
    static func reset() {
        step = nil
        pendingInput = nil
        streamingOverride = nil
        leanOverride = nil
        removeObservers()
    }
}
