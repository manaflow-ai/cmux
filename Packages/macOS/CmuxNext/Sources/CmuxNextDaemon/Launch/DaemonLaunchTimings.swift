import os
import Synchronization

/// Marks of the daemon start path (login environment, `server ensure`,
/// connect, handshake) for the App's `debug.timings` and Instruments
/// (signpost events, category "stalls"). Marks come from any thread.
public enum DaemonLaunchTimings {
    private static let sink = Mutex<(@Sendable (String) -> Void)?>(nil)
    private static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")

    /// Installs the receiver of marks (once, at launch).
    public static func install(_ receiver: @escaping @Sendable (String) -> Void) {
        sink.withLock { $0 = receiver }
    }

    static func mark(_ name: String) {
        signposter.emitEvent("daemon", "\(name, privacy: .public)")
        let receiver = sink.withLock { $0 }
        receiver?(name)
    }
}
