import CoreFoundation

/// One observer of the main run loop, read from a `CFCopyDescription` dump of a run loop
/// (``CommitBoundaryAudit``).
public nonisolated struct CommitBoundaryObserver: Sendable, Hashable, Comparable {
    /// Its order (lower runs first within an activity).
    public var order: Int
    /// The callout's symbol (`_ZN2CA11Transaction17observer_callbackEP19__CFRunLoopObservermPv`).
    public var callout: String
    /// Its `CFRunLoopActivity` bits, or nil when the dump showed none.
    public var activities: UInt?

    /// An observer of a dump.
    ///
    /// - Parameters:
    ///   - order: The observer's order.
    ///   - callout: The callout symbol.
    ///   - activities: The activity bits, nil when unknown.
    public init(order: Int, callout: String, activities: UInt?) {
        self.order = order
        self.callout = callout
        self.activities = activities
    }

    /// Whether this is Core Animation's transaction (commit) observer.
    public var isCoreAnimation: Bool {
        callout.contains("CA11Transaction") || callout.contains("CA::Transaction")
    }

    /// Whether it fires where ``CommitBoundary`` does (before waiting or on exit); an observer
    /// whose activities are unknown counts.
    public var firesAtTheBoundary: Bool {
        guard let activities else { return true }
        return activities & (CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue) != 0
    }

    public static func < (lhs: CommitBoundaryObserver, rhs: CommitBoundaryObserver) -> Bool {
        (lhs.order, lhs.callout) < (rhs.order, rhs.callout)
    }
}
