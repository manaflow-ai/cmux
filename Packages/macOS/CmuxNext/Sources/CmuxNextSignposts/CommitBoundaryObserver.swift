import CoreFoundation

/// One observer of the main run loop, read from a `CFCopyDescription` dump of a run loop
/// (``CommitBoundaryAudit``).
public nonisolated struct CommitBoundaryObserver: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Its order (lower runs first within an activity).
    public var order: Int
    /// The callout's symbol (`_ZN2CA11Transaction17observer_callbackEP19__CFRunLoopObservermPv`).
    public var callout: String
    /// Its `CFRunLoopActivity` bits, or nil when the dump showed none.
    public var activities: UInt?
    /// The observer's whole entry in the dump (`<CFRunLoopObserver ...>{valid = ..., callout = ...}`), so
    /// a report shows what it is even when the callout is a block trampoline.
    public var dumpText: String

    /// An observer of a dump.
    ///
    /// - Parameters:
    ///   - order: The observer's order.
    ///   - callout: The callout symbol.
    ///   - activities: The activity bits, nil when unknown.
    ///   - dumpText: The observer's whole dump entry (default: none known).
    public init(order: Int, callout: String, activities: UInt?, dumpText: String = "") {
        self.order = order
        self.callout = callout
        self.activities = activities
        self.dumpText = dumpText
    }

    /// The dump entry, or order and callout when none is known.
    public var description: String {
        dumpText.isEmpty ? "order \(order), callout \(callout)" : dumpText
    }

    /// The autorelease pool pop AppKit and Foundation run at the very end of every turn (order INT_MAX):
    /// it drains objects, it lays out, displays or commits nothing.
    public var isAutoreleasePoolPop: Bool {
        callout.contains("AutoreleasePool") && order == Int(Int32.max)
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

    public static func == (lhs: CommitBoundaryObserver, rhs: CommitBoundaryObserver) -> Bool {
        (lhs.order, lhs.callout, lhs.activities) == (rhs.order, rhs.callout, rhs.activities)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(order)
        hasher.combine(callout)
        hasher.combine(activities)
    }

    public static func < (lhs: CommitBoundaryObserver, rhs: CommitBoundaryObserver) -> Bool {
        (lhs.order, lhs.callout) < (rhs.order, rhs.callout)
    }
}
