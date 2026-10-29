/// The type of a main-thread task queue: it gives the queue its priority and the rule that picks
/// between queues of that priority (plans/cmux-next/sequence-manager-DESIGN.md section 2.1;
/// Chrome's `QueueType` in content/browser/scheduler/browser_task_queues.h and `QueuePriority` in
/// base/task/sequence_manager/task_queue.h).
///
/// Priority belongs to the queue, not to each task: a post site picks a queue, and the queue's type
/// is the priority.
public enum MainQueueType: Sendable, CaseIterable, CustomStringConvertible {
    /// The manager's own work: wake-up continuations, policy updates. Never disabled, never fenced.
    case control
    /// What the person's own input posts and must run before any other task.
    case input
    /// The display clock's observers for this frame (not part of the work batch).
    case frame
    /// The async rest of a person's action.
    case userBlocking
    /// Launch steps that run after the first frame: visible's priority and budget, fenced until the first frame commits.
    case startup
    /// Visible changes the person did not cause.
    case visible
    /// CLI, MCP, agent, socket and page automation.
    case automation
    /// Work nobody sees this frame.
    case background
    /// Idle tasks, run only inside an idle period.
    case idle

    /// How the selector picks between queues of one priority.
    public enum Selection: Sendable {
        /// The queue whose head was enqueued first (Chrome's `TaskQueueSelector` rule).
        case oldestFirst
        /// The queue that ran least recently, FIFO inside each queue: a queue that floods holds a
        /// later one for one task only (today's budgeted frame clients and control connections).
        case roundRobin
    }

    /// The priority: lower runs first (Chrome `QueuePriority`, `uint8_t`). `startup` shares `visible`'s.
    public var priority: UInt8 {
        switch self {
        case .control: 0
        case .input: 1
        case .frame: 2
        case .userBlocking: 3
        case .startup, .visible: 4
        case .automation: 5
        case .background: 6
        case .idle: 7
        }
    }

    /// The rule between queues of this type's priority; types that share a priority share it.
    public var selection: Selection {
        switch self {
        case .control, .input, .frame, .idle: .oldestFirst
        case .userBlocking, .startup, .visible, .automation, .background: .roundRobin
        }
    }

    public var description: String {
        switch self {
        case .control: "control"
        case .input: "input"
        case .frame: "frame"
        case .userBlocking: "userBlocking"
        case .startup: "startup"
        case .visible: "visible"
        case .automation: "automation"
        case .background: "background"
        case .idle: "idle"
        }
    }
}
