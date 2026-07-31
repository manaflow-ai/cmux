import Foundation

/// Defines nested deadlines for one browser screenshot request.
public struct BrowserScreenshotTimingBudget: Sendable, Equatable {
    /// Maximum number of capture and verification attempts.
    public let maximumAttempts: Int
    /// Time reserved for acquiring and releasing the browser render lease.
    public let leaseSetupAllowance: TimeInterval
    /// Deadline for each DOM probe collection.
    public let probeCollectionAllowance: TimeInterval
    /// Deadline for the final page-state synchronization operation.
    public let synchronizationAllowance: TimeInterval
    /// Deadline for each WebKit snapshot callback.
    public let snapshotCompletionAllowance: TimeInterval
    /// Delivery margin between the capture lease and the app socket waiter.
    public let socketDeliveryAllowance: TimeInterval
    /// Delivery margin between the app socket waiter and the CLI client.
    public let clientDeliveryAllowance: TimeInterval

    /// Creates a timing budget whose outer waiters contain every inner deadline.
    ///
    /// - Parameters:
    ///   - maximumAttempts: Number of capture and verification attempts; defaults to two.
    ///   - leaseSetupAllowance: Time reserved outside capture attempts; defaults to four seconds.
    ///   - probeCollectionAllowance: Per-probe deadline; defaults to one second.
    ///   - synchronizationAllowance: Page-state barrier deadline; defaults to one second.
    ///   - snapshotCompletionAllowance: Snapshot callback deadline; defaults to ten seconds.
    ///   - socketDeliveryAllowance: App socket delivery margin; defaults to two seconds.
    ///   - clientDeliveryAllowance: CLI response delivery margin; defaults to three seconds.
    public init(
        maximumAttempts: Int = 2,
        leaseSetupAllowance: TimeInterval = 4,
        probeCollectionAllowance: TimeInterval = 1,
        synchronizationAllowance: TimeInterval = 1,
        snapshotCompletionAllowance: TimeInterval = 10,
        socketDeliveryAllowance: TimeInterval = 2,
        clientDeliveryAllowance: TimeInterval = 3
    ) {
        self.maximumAttempts = maximumAttempts
        self.leaseSetupAllowance = leaseSetupAllowance
        self.probeCollectionAllowance = probeCollectionAllowance
        self.synchronizationAllowance = synchronizationAllowance
        self.snapshotCompletionAllowance = snapshotCompletionAllowance
        self.socketDeliveryAllowance = socketDeliveryAllowance
        self.clientDeliveryAllowance = clientDeliveryAllowance
    }

    /// Maximum duration of the app's render lease.
    public var captureLeaseTimeout: TimeInterval {
        leaseSetupAllowance + TimeInterval(maximumAttempts) * (
            probeCollectionAllowance * 2
                + synchronizationAllowance
                + snapshotCompletionAllowance
        )
    }

    /// Maximum duration of the app's socket response waiter.
    public var socketResponseTimeout: TimeInterval {
        captureLeaseTimeout + socketDeliveryAllowance
    }

    /// Maximum duration of the CLI's socket response waiter.
    public var clientResponseTimeout: TimeInterval {
        socketResponseTimeout + clientDeliveryAllowance
    }
}
