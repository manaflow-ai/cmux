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

    /// Observers after the boundary that are known to lay out, display and commit nothing, by symbol
    /// (reviewed per macOS major from real dumps; plans/cmux-next/architecture-refactor-DESIGN.md
    /// section 7): the autorelease pool pop at INT_MAX (`_wrapRunLoopWithAutoreleasePoolHandler`), and
    /// the run loop's idle tracking, which records when the loop goes to sleep (`idle_before_waiting`
    /// at Int.max, paired with `idle_after_waiting` at Int.min; seen on macOS 26).
    static let reviewedAfterBoundary: Set<String> = ["_wrapRunLoopWithAutoreleasePoolHandler", "idle_before_waiting"]

    /// Whether this observer is on ``reviewedAfterBoundary``.
    public var isReviewedAfterBoundary: Bool {
        Self.reviewedAfterBoundary.contains(callout)
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
