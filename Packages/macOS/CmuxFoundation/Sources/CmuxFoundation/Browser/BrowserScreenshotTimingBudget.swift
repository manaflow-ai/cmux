public import Foundation

/// Defines nested deadlines for one browser screenshot request.
public struct BrowserScreenshotTimingBudget: Sendable, Equatable {
    /// Maximum number of capture and verification attempts.
    public let maximumAttempts: Int
    /// Deadline for restoring a discarded web view to its expected URL.
    public let expectedURLAllowance: TimeInterval
    /// Deadline for the pre-capture JavaScript layout flush.
    public let preparationJavaScriptAllowance: TimeInterval
    /// Headroom for render-host setup, layout, image normalization, and task delivery.
    public let leaseOverheadAllowance: TimeInterval
    /// Deadline for each DOM probe collection.
    public let probeCollectionAllowance: TimeInterval
    /// Deadline for the final page-state synchronization operation.
    public let synchronizationAllowance: TimeInterval
    /// Deadline for each WebKit snapshot callback.
    public let snapshotCompletionAllowance: TimeInterval
    /// Delivery margin between the capture lease and the app socket waiter.
    public let socketDeliveryAllowance: TimeInterval
    /// Deadline for checking and recovering browser liveness after capture timeout.
    public let livenessProbeAllowance: TimeInterval
    /// Delivery margin between the app socket waiter and the CLI client.
    public let clientDeliveryAllowance: TimeInterval

    /// Creates a timing budget whose outer waiters contain every inner deadline.
    ///
    /// - Parameters:
    ///   - maximumAttempts: Number of capture and verification attempts; defaults to two.
    ///   - expectedURLAllowance: Restored-URL deadline; defaults to five seconds.
    ///   - preparationJavaScriptAllowance: Layout-flush deadline; defaults to one second.
    ///   - leaseOverheadAllowance: Non-deadlined capture overhead; defaults to two seconds.
    ///   - probeCollectionAllowance: Per-probe deadline; defaults to one second.
    ///   - synchronizationAllowance: Page-state barrier deadline; defaults to one second.
    ///   - snapshotCompletionAllowance: Snapshot callback deadline; defaults to ten seconds.
    ///   - socketDeliveryAllowance: App socket delivery margin; defaults to two seconds.
    ///   - livenessProbeAllowance: Post-timeout recovery deadline; defaults to 2.5 seconds.
    ///   - clientDeliveryAllowance: CLI response delivery margin; defaults to three seconds.
    public init(
        maximumAttempts: Int = 2,
        expectedURLAllowance: TimeInterval = 5,
        preparationJavaScriptAllowance: TimeInterval = 1,
        leaseOverheadAllowance: TimeInterval = 2,
        probeCollectionAllowance: TimeInterval = 1,
        synchronizationAllowance: TimeInterval = 1,
        snapshotCompletionAllowance: TimeInterval = 10,
        socketDeliveryAllowance: TimeInterval = 2,
        livenessProbeAllowance: TimeInterval = 2.5,
        clientDeliveryAllowance: TimeInterval = 3
    ) {
        self.maximumAttempts = maximumAttempts
        self.expectedURLAllowance = expectedURLAllowance
        self.preparationJavaScriptAllowance = preparationJavaScriptAllowance
        self.leaseOverheadAllowance = leaseOverheadAllowance
        self.probeCollectionAllowance = probeCollectionAllowance
        self.synchronizationAllowance = synchronizationAllowance
        self.snapshotCompletionAllowance = snapshotCompletionAllowance
        self.socketDeliveryAllowance = socketDeliveryAllowance
        self.livenessProbeAllowance = livenessProbeAllowance
        self.clientDeliveryAllowance = clientDeliveryAllowance
    }

    /// Maximum duration of the app's render lease.
    public var captureLeaseTimeout: TimeInterval {
        expectedURLAllowance
            + preparationJavaScriptAllowance
            + leaseOverheadAllowance
            + TimeInterval(maximumAttempts) * (
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
        socketResponseTimeout
            + livenessProbeAllowance
            + clientDeliveryAllowance
    }
}
