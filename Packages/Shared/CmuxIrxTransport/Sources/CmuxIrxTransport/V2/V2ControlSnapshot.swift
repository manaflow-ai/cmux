import Foundation

/// A complete observation, so a slow consumer can safely skip older snapshots.
public struct V2ControlSnapshot: Sendable, Equatable {
    /// The backend socket's status, independent of actual IROH peer reachability.
    public enum Status: Sendable, Equatable {
        /// No control work is running.
        case stopped
        /// Setup is in progress while cached peer work may run independently.
        case connecting
        /// The current control socket has completed setup and enrollment.
        case ready
        /// One owned reconnect task is waiting for its retry deadline.
        case backingOff
    }

    /// The current backend lifecycle state.
    public let status: Status
    /// All current cached authority and credentials in this scope.
    public let cache: V2CachedState
    /// Most recent stable error, cleared by the relevant successful work.
    public let failure: V2ControlFailure?
    /// Monotonically increasing local publication counter, unrelated to server revisions.
    public let sequence: UInt64
}
