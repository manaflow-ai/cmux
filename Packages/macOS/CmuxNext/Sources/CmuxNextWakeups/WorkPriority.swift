public import Dispatch
public import Foundation

/// The priority of one piece of off-main work, as Chrome's `base::TaskPriority` states it.
///
/// Every off-main task says on purpose how much a person waits for it (plans/cmux-next/PATTERNS.md P14).
/// It is the off-main side of the one priority model whose main-thread side is ``MainWorkClass``: work that
/// a main-thread task of class `C` starts takes `WorkPriority(C)`, so there is no second set of names.
///
/// | WorkPriority | MainWorkClass | GCD QoS | TaskPriority |
/// |---|---|---|---|
/// | ``userBlocking`` | input, frame | `.userInitiated` | `.high` |
/// | ``userVisible`` | visible | `.default` | `.medium` |
/// | ``bestEffort`` | automation, background | `.utility` | `.utility` |
/// | ``idle`` | (none: opt-in only) | `.background` | `.background` |
///
/// `.userInteractive` belongs to the main thread and the few threads a frame waits for (render, PTY read,
/// the daemon line reader, the watchdog); no ``BackgroundWork`` lane ever runs at it.
///
/// ```swift
/// let icon = try await work.run(.userVisible, mayBlock: .files) { try Data(contentsOf: url) }
/// ```
public enum WorkPriority: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// Work nobody waits for and that may wait without limit: indexing, telemetry upload, prefetch, cache
    /// cleanup. Runs at QoS `.background` (efficiency cores, throttled disk I/O), so it can take seconds
    /// under load. Never use it for the journal, for anything quit waits for, or for anything a UI path
    /// awaits later (a later await boosts it, but the boost cannot undo time already lost).
    case idle
    /// Work a person does not wait for now: saves, the journal, automation (agent, CLI, MCP) work
    /// off the main thread. QoS `.utility`: not disk-throttled, so it finishes quickly when the
    /// machine is quiet.
    case bestEffort
    /// Work whose result shows on screen soon: a thumbnail, an icon, a file a page shows.
    case userVisible
    /// Work a person waits for right now: the result of a key, a click or an open.
    case userBlocking

    /// The off-main priority of work that a main-thread task of `workClass` starts.
    public init(_ workClass: MainWorkClass) {
        switch workClass {
        case .input, .frame: self = .userBlocking
        case .visible: self = .userVisible
        case .automation, .background: self = .bestEffort
        }
    }

    /// The level of a Swift task priority (`Task.currentPriority`): `.high` and above is
    /// ``userBlocking`` (the main thread runs at `.userInteractive`), `.medium` ``userVisible``,
    /// `.utility` ``bestEffort`` and below that ``idle``.
    public init(_ priority: TaskPriority) {
        switch priority.rawValue {
        case TaskPriority.high.rawValue...: self = .userBlocking
        case TaskPriority.medium.rawValue...: self = .userVisible
        case TaskPriority.utility.rawValue...: self = .bestEffort
        default: self = .idle
        }
    }

    /// The GCD quality of service a lane runs this level's work at.
    public var qos: DispatchQoS {
        switch self {
        case .userBlocking: .userInitiated
        case .userVisible: .default
        case .bestEffort: .utility
        case .idle: .background
        }
    }

    /// The quality of service a child process of this level runs at (`Process.qualityOfService`);
    /// never `.userInteractive`.
    public var processQoS: QualityOfService {
        switch self {
        case .userBlocking: .userInitiated
        case .userVisible: .default
        case .bestEffort: .utility
        case .idle: .background
        }
    }

    /// The Swift task priority of this level, for a `Task(priority:)` that does not block.
    public var taskPriority: TaskPriority {
        switch self {
        case .userBlocking: .high
        case .userVisible: .medium
        case .bestEffort: .utility
        case .idle: .background
        }
    }

    public static func < (lhs: WorkPriority, rhs: WorkPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .idle: "idle"
        case .bestEffort: "bestEffort"
        case .userVisible: "userVisible"
        case .userBlocking: "userBlocking"
        }
    }
}
