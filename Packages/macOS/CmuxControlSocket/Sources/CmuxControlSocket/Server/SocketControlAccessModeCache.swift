public import CmuxSettings
import os

/// A lock-backed snapshot of the resolved socket mode for hot authorization reads.
///
/// The composition root updates this cache whenever the authoritative policy
/// resolver reconciles configuration. Socket workers read the immutable mode
/// snapshot without resolving `UserDefaults` or profile state per command.
public final class SocketControlAccessModeCache: @unchecked Sendable {
    // Synchronous socket-worker reads are a short compare/load operation. The
    // lock protects only this value and never spans policy or filesystem I/O.
    private let state: OSAllocatedUnfairLock<SocketControlMode>

    /// Creates a mode cache with the startup snapshot.
    /// - Parameter initialMode: The mode resolved by the composition root.
    public init(initialMode: SocketControlMode) {
        state = OSAllocatedUnfairLock(initialState: initialMode)
    }

    /// The latest mode published by the composition root.
    public var current: SocketControlMode {
        state.withLock { $0 }
    }

    /// Publishes a newly resolved mode to socket workers.
    /// - Parameter mode: The authoritative effective mode.
    public func update(_ mode: SocketControlMode) {
        state.withLock { $0 = mode }
    }
}
