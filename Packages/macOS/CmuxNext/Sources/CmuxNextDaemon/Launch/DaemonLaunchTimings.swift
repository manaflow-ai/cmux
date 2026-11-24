public import Foundation
import os
import CmuxNextCompat

/// Marks of the daemon start path (login environment, `server ensure`,
/// connect, handshake) for the App's `debug.timings` and Instruments
/// (signpost events, category "stalls"). Marks come from any thread. The
/// first connect starts in `main`, before the App installs its receiver, so
/// marks are kept with their time until then.
public final class DaemonLaunchTimings: Sendable {
    public static let shared = DaemonLaunchTimings()
    /// The launch's daemon owner was started for it (`server ensure` said `started`): the spawn is in this launch's time.
    public static let spawned = "daemon.spawned"
    /// The launch connected to an owner already running (`server status`, `ensure` said `running`, or a remembered socket).
    public static let reused = "daemon.reused"
    private struct State {
        var sink: (@Sendable (String, Date) -> Void)?
        var early: [(String, Date)] = []
    }

    private let state = Mutex(State())
    private let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")
    /// The first-interaction marks' progress (``inputSent()``, ``outputDecoded()``).
    let inputStage = Atomic<UInt8>(0)

    /// Installs the receiver of marks (once, at launch) and hands it the
    /// marks made before.
    public func install(_ receiver: @escaping @Sendable (String, Date) -> Void) {
        let early = state.withLock { state -> [(String, Date)] in
            state.sink = receiver
            defer { state.early.removeAll() }
            return state.early
        }
        for (name, date) in early { receiver(name, date) }
    }

    public func mark(_ name: String) {
        signposter.emitEvent("daemon", "\(name, privacy: .public)")
        let now = Date()
        let receiver = state.withLock { state -> (@Sendable (String, Date) -> Void)? in
            if state.sink == nil, state.early.count < 64 { state.early.append((name, now)) }
            return state.sink
        }
        receiver?(name, now)
    }
}
