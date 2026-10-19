import Foundation

/// Bounds repeated admission passes when the app cannot settle ownership
/// evidence during a restore.
public struct AgentRestoreAdmissionRecoveryBudget {
    public static let defaultTimeout: TimeInterval = 120
    public static let defaultMaximumAttempts = 3

    public let deadline: Date
    public let maximumAttempts: Int
    private let now: () -> Date
    public private(set) var attempts = 0

    public init(
        timeout: TimeInterval = Self.defaultTimeout,
        maximumAttempts: Int = Self.defaultMaximumAttempts,
        start: Date = .now,
        now: @escaping () -> Date = { Date.now }
    ) {
        self.deadline = start.addingTimeInterval(max(0, timeout))
        self.maximumAttempts = max(0, maximumAttempts)
        self.now = now
    }

    /// Reserves one admission pass while both the count and wall-clock budget remain.
    public mutating func beginAttempt() -> Bool {
        guard attempts < maximumAttempts, now() < deadline else { return false }
        attempts += 1
        return true
    }

    /// Gives one socket request no more than thirty seconds and never beyond
    /// the outer recovery deadline.
    public var responseTimeout: TimeInterval {
        min(30, max(0.1, deadline.timeIntervalSince(now())))
    }
}
