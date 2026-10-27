import Darwin

/// Where and when a main-thread task was posted, and the state of the node it belongs to: what
/// Chrome keeps on every `PendingTask` (`base/pending_task.h`: `posted_from`, a `base::Location`
/// from `FROM_HERE`, and `queue_time`). The scheduler's posts (``MainWorkScheduler/post(_:owner:file:line:_:)``,
/// ``MainTaskQueue/post(file:line:_:)``) take one at the post and run the task with it
/// (``MainFrameBudget/run(_:owner:posted:_:)``); the board records the task's wait (its start minus
/// ``enqueueNanos``) and run time in the ``MainOwnerLedger`` under its owner, class, ``site`` and
/// ``node`` state.
///
/// A plain value of trivial fields: building one allocates nothing and copies no string.
///
/// ```swift
/// let post = MainTaskPost(enqueueNanos: clock(), node: .visible)   // file and line: the caller's
/// budget.run(.visible, owner: owner, posted: post) { apply(rows) }
/// ```
public struct MainTaskPost: Sendable {
    /// The state of the ``VisibilityNode`` a task belongs to when it starts (Chrome's
    /// `content::Visibility`), or ``none`` for a node-free post. The ledger keeps it per task, so
    /// `debug.main_budget` shows whether hidden nodes run visible or automation work.
    public enum NodeState: UInt8, Sendable, CaseIterable, CustomStringConvertible {
        /// The task belongs to no node.
        case none
        case hidden
        case occluded
        case visible

        /// The state of a node whose effective visibility is `visibility`.
        public init(_ visibility: Visibility) {
            switch visibility {
            case .hidden: self = .hidden
            case .occluded: self = .occluded
            case .visible: self = .visible
            }
        }

        public var description: String {
            switch self {
            case .none: "none"
            case .hidden: "hidden"
            case .occluded: "occluded"
            case .visible: "visible"
            }
        }
    }

    /// Where it was posted (`posted_from`).
    public let site: MainPostSite
    /// When it was posted (`CLOCK_UPTIME_RAW` nanoseconds: the clock of the budget that runs it).
    public let enqueueNanos: UInt64
    /// The state of the task's node when it starts.
    public let node: NodeState

    /// - Parameters:
    ///   - site: Where it was posted.
    ///   - enqueueNanos: When it was posted, on the clock of the budget that runs it.
    ///   - node: The state of the task's node (``NodeState/none`` for a node-free post).
    public init(site: MainPostSite, enqueueNanos: UInt64, node: NodeState = .none) {
        self.site = site
        self.enqueueNanos = enqueueNanos
        self.node = node
    }

    /// - Parameters:
    ///   - file: The posting file; the default is the caller's.
    ///   - line: The posting line; the default is the caller's.
    ///   - enqueueNanos: When it was posted; the default is `CLOCK_UPTIME_RAW` now, the app budget's
    ///     clock. A budget with an injected clock needs the same clock here.
    ///   - node: The state of the task's node (``NodeState/none`` for a node-free post).
    public init(file: StaticString = #fileID, line: UInt = #line, enqueueNanos: UInt64 = MainTaskPost.uptimeNanos(),
                node: NodeState = .none) {
        self.init(site: MainPostSite(file: file, line: line), enqueueNanos: enqueueNanos, node: node)
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds now: the app budget's clock.
    public static func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// This post with the state its node has when the task starts (a node queue may hold a post
    /// while its node is hidden and run it after the node changed).
    public func starting(in node: NodeState) -> MainTaskPost {
        MainTaskPost(site: site, enqueueNanos: enqueueNanos, node: node)
    }
}
