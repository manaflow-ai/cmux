/// Where a launch task runs: on the main thread, or on a ``BackgroundWork`` lane at a stated
/// ``WorkPriority`` (Chrome's `destination_runner` in `AfterStartupTaskUtils::PostTask`,
/// chrome/browser/after_startup_task_utils.cc).
///
/// A post names its destination; there is no default. The two `post` methods of
/// ``StartupScheduler`` take ``Main`` (`on: .main`, main-actor work) or ``Lane``
/// (`on: .lane(.files, .bestEffort)`, `@Sendable` work that runs off main), so the compiler checks
/// that lane work never touches main-actor state. This enum is how a record names the destination.
///
/// ```swift
/// startup.post(.afterStartup, "Palette.prepare", on: .main) { palette.prepare() }
/// startup.post(.afterStartup, "Launch.cleanup", on: .lane(.files, .idle)) { cleanup.run() }
/// ```
public enum StartupDestination: Sendable, Equatable, CustomStringConvertible {
    /// The main thread.
    case main
    /// A ``BackgroundWork`` lane at a priority.
    case lane(BlockingLane, WorkPriority)

    public var description: String {
        switch self {
        case .main: "main"
        case .lane(let lane, let priority): "lane.\(lane).\(priority)"
        }
    }

    /// The main-thread destination of a post (`on: .main`): its work is main-actor code.
    public struct Main: Sendable {
        private init() {}

        /// The main thread.
        public static var main: Main { Main() }
    }

    /// A lane destination of a post (`on: .lane(.files, .bestEffort)`): its work runs on that
    /// ``BackgroundWork`` lane, never on main.
    public struct Lane: Sendable {
        /// The kind of blocking work the task does.
        public let blockingLane: BlockingLane
        /// How much a person waits for it (its QoS).
        public let priority: WorkPriority

        private init(blockingLane: BlockingLane, priority: WorkPriority) {
            self.blockingLane = blockingLane
            self.priority = priority
        }

        /// `lane` at `priority`.
        public static func lane(_ lane: BlockingLane, _ priority: WorkPriority) -> Lane {
            Lane(blockingLane: lane, priority: priority)
        }

        /// The destination as a record names it.
        public var destination: StartupDestination { .lane(blockingLane, priority) }
    }
}
