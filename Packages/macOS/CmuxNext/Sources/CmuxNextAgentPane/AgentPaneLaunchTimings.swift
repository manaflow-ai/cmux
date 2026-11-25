public import Foundation
import CmuxNextCompat
import struct CmuxNextControl.LaunchMarkSink
import os

/// Marks of the first agent pane's load (view made, page loaded, page asked
/// for the handshake, handshake answered) and of the acpmux lookup it waits on
/// (lookup start and end, a version handoff, a daemon spawn) for the App's
/// `debug.timings` and Instruments (signpost events, category "stalls"). Marks
/// come from any thread: the lookup runs on the host actor, off main. The App
/// installs the receiver at launch and keeps the first time of each name; a
/// mark made before that is kept with its time until then.
/// The relaunch-reconnect bench reads them (scripts/cmux-next/bench_relaunch_reconnect.py).
public nonisolated final class AgentPaneLaunchTimings: Sendable {
    // lint:allow singleton: one process-wide launch-mark recorder; marks come from any thread before the App
    // can hand an instance around (the host actor's acpmux lookup, the first page), 17 call sites.
    public static let shared = AgentPaneLaunchTimings()
    private struct State {
        var sink: (@Sendable (String, Date) -> Void)?
        var early: [(String, Date)] = []
        var listeners: [@Sendable (String) -> Void] = []
        var layoutSettled = false
        var inputEchoed = false
    }

    // Lock carve-out: a synchronous swap of the receiver, early marks and once-flags from any marking thread,
    // no I/O under it.
    private let state = Mutex(State())
    private let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")

    public func install(_ receiver: @escaping @Sendable (String, Date) -> Void) {
        let early = state.withLock { state -> [(String, Date)] in
            state.sink = receiver
            defer { state.early.removeAll() }
            return state.early
        }
        for (name, date) in early { receiver(name, date) }
    }

    /// Tells `listener` each mark's name after the receiver took it (on the marking thread; keep it cheap): the
    /// launch's `LaunchTimesRecorder` rewrites its row when the prior chat's marks are in (CMUX-119).
    public func listen(_ listener: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.listeners.append(listener) }
    }

    /// Records `name` at `date` (now by default; a page's report carries its own wall-clock time).
    func mark(_ name: String, at date: Date = Date()) {
        signposter.emitEvent("agent_pane", "\(name, privacy: .public)")
        let (receiver, listeners) = state.withLock { state -> ((@Sendable (String, Date) -> Void)?, [@Sendable (String) -> Void]) in
            if state.sink == nil, state.early.count < 64 { state.early.append((name, date)) }
            return (state.sink, state.listeners)
        }
        receiver?(name, date)
        for listener in listeners { listener(name) }
    }

    /// The first chat composer's echo of a typed key (`pane.inputEchoed`, webviews launchInputEcho.ts), once per
    /// process: the launch mark `agent_pane.input_echoed` at the page's wall-clock `date` (the frame that drew the
    /// key), the chat front's first interaction (LaunchStages `first_interaction`, scripts/ci/launch_tti_check.py).
    func inputEchoed(at date: Date) {
        guard LaunchMarkSink.shared.isActive else { return }
        let first = state.withLock { state -> Bool in
            defer { state.inputEchoed = true }
            return !state.inputEchoed
        }
        if first { mark("agent_pane.input_echoed", at: date) }
    }

    /// The first chat page's launch settle (`pane.launchSettle`, webviews launchSettle.ts), once per process:
    /// `web.layout.settle` is a time mark (the page's wall-clock `date`, on the launch marks' process-start clock
    /// through the receiver); the rest are values, not times, so they go straight to the launch harness's
    /// stream (``LaunchMarkSink``, nothing without one): `web.layout.max_move` and
    /// `web.layout.max_move.<element>` in CSS px, `web.layout.shifts` a count.
    func layoutSettle(at date: Date, maxMovePx: Double, element: String, shifts: Int) {
        // No harness, no marks: not even the in-memory launch mark.
        guard LaunchMarkSink.shared.isActive else { return }
        let first = state.withLock { state -> Bool in
            defer { state.layoutSettled = true }
            return !state.layoutSettled
        }
        guard first else { return }
        mark("web.layout.settle", at: date)
        // One token of the `<name> <value>` line: the page names a short kind; anything else reads `other`.
        let named = element.count <= 32 && !element.isEmpty
            && element.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "-" }
        let sink = LaunchMarkSink.shared
        sink.write(name: "web.layout.max_move", ms: maxMovePx)
        sink.write(name: "web.layout.max_move.\(named ? element : "other")", ms: maxMovePx)
        sink.write(name: "web.layout.shifts", ms: Double(shifts))
    }
}
