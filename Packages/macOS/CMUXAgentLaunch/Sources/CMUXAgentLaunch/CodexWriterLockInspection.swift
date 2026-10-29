import Foundation

/// A point-in-time probe of Codex's writer lock, never a reservation to launch.
public struct CodexWriterLockInspection: Equatable, Sendable {
    /// Whether the exact file is free, actively locked, or cannot be inspected.
    public enum State: Equatable, Sendable {
        /// No writer held the lock at the instant of the probe.
        case available
        /// Another descriptor held an incompatible kernel lock.
        case active
        /// Codex is changing its lock namespace; retry without inferring an owner.
        case changing
        /// The lock could not be inspected safely; do not start a writer.
        case unavailable
    }

    /// The result of a nonblocking kernel lock probe.
    public let state: State
    /// The home/account whose lock was inspected.
    public let codexHome: String
    /// The exact lock filename, suitable for a read-only diagnostic command.
    public let lockPath: String
    let device: Int32?
    let inode: UInt64?

    /// Whether two observations identify the same on-disk lock file.
    /// - Parameter other: An earlier observation.
    /// - Returns: False when either observation lacks an inode.
    public func deviceAndInodeMatch(_ other: Self) -> Bool {
        device != nil && inode != nil && device == other.device && inode == other.inode
    }
}
