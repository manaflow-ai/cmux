@preconcurrency import XPC

/// Owns cancellation of one immutable libxpc connection handle.
///
/// Safety: libxpc connection handles are thread-safe, the handle never changes,
/// and cancellation occurs exactly once when this owner is released.
final class SimulatorDTUHIDConnectionLifetime: @unchecked Sendable {
    let connection: xpc_connection_t

    init(connection: xpc_connection_t) {
        self.connection = connection
    }

    deinit {
        xpc_connection_cancel(connection)
    }
}
