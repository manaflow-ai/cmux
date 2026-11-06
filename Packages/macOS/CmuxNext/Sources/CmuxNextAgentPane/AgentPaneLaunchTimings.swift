public import Foundation
import CmuxNextCompat
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
    public static let shared = AgentPaneLaunchTimings()
    private struct State {
        var sink: (@Sendable (String, Date) -> Void)?
        var early: [(String, Date)] = []
    }

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

    func mark(_ name: String) {
        signposter.emitEvent("agent_pane", "\(name, privacy: .public)")
        let now = Date()
        let receiver = state.withLock { state -> (@Sendable (String, Date) -> Void)? in
            if state.sink == nil, state.early.count < 64 { state.early.append((name, now)) }
            return state.sink
        }
        receiver?(name, now)
    }
}
