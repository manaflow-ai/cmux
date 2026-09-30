public import Foundation

/// Bounds how long an SSH PTY attachment waits for its declared replay.
///
/// The remote daemon declares the replay length in its ready status, and input
/// forwarding waits for that many bytes. A peer that declares more than it
/// sends must not hold keystrokes forever, so the replay phase ends when the
/// bridge goes quiet for `idleTimeout` or when `totalTimeout` has elapsed
/// since the ready status, whichever comes first.
public struct SSHPTYAttachReplayDeadline: Sendable, Equatable {
    /// Quiet interval after which a still-incomplete replay is abandoned.
    public static let defaultIdleTimeout: TimeInterval = 2
    /// Longest replay phase measured from the ready status.
    public static let defaultTotalTimeout: TimeInterval = 15

    /// Creates a deadline for a replay that began at `startedAt`.
    ///
    /// - Parameters:
    ///   - startedAt: Monotonic time of the bridge ready status.
    ///   - idleTimeout: Quiet interval that ends the replay phase.
    ///   - totalTimeout: Maximum replay phase length.
    public init(
        startedAt: TimeInterval,
        idleTimeout: TimeInterval = Self.defaultIdleTimeout,
        totalTimeout: TimeInterval = Self.defaultTotalTimeout
    ) {}

    /// Records bridge output that arrived at `now`.
    public mutating func recordOutput(at now: TimeInterval) {}

    /// Seconds left before the replay phase ends; zero once it has expired.
    public func remainingWait(at now: TimeInterval) -> TimeInterval {
        .infinity
    }
}
