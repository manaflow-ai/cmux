public import Foundation
import CmuxNextCompat
import CmuxNextSignposts

/// Marks of the daemon start path (login environment, `server ensure`,
/// connect, handshake) for the App's `debug.timings` and Instruments
/// (`launch.daemon` events, category "launch"). Marks come from any thread.
/// The first connect starts in `main`, before the App installs its receiver,
/// so marks are kept with their time until then.
public final class DaemonLaunchTimings: @unchecked Sendable {
    public static let shared = DaemonLaunchTimings()
    private struct State {
        var sink: (@Sendable (String, Date) -> Void)?
        var early: [(String, Date)] = []
    }

    private let state = Mutex(State())
    private let signposter: Signposter

    /// - Parameter signposter: Where each mark's `launch.daemon` event goes (a `launch` signposter).
    init(signposter: Signposter = .launch) {
        self.signposter = signposter
    }

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
        signposter.launchStep(.daemon, name)
        let now = Date()
        let receiver = state.withLock { state -> (@Sendable (String, Date) -> Void)? in
            if state.sink == nil, state.early.count < 64 { state.early.append((name, now)) }
            return state.sink
        }
        receiver?(name, now)
    }
}
