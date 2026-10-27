/// The priority class of one piece of main-thread work (plans/cmux-next/main-thread-budget.md).
///
/// The main thread does input dispatch, the minimal mutation of visible state and the Core
/// Animation commit. Everything the app schedules there runs in one of these classes, ordered as
/// Chrome orders its UI thread (`content/browser/scheduler/browser_task_queues.h`: kUserInput,
/// kUserBlocking, kUserVisible, kBestEffort): a person's input first, then frame-locked work, then
/// the rest of a person's action, then visible model updates, then automation, then background
/// work, then idle work. ``MainFrameBudget`` gives each budgeted class a per-frame budget and makes
/// it yield while input is pending; idle work runs only in the ``IdleScheduler``'s idle periods,
/// with a deadline instead of a share.
public enum MainWorkClass: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// A person's input, or an injected stand-in for it (`debug.key`): runs on the next main run
    /// loop turn, before any batch, never deferred. While input work is queued, every budgeted
    /// class yields.
    case input
    /// Work locked to the display frame: springs, autoscroll, frame probes, terminal frame holds.
    /// Runs every frame, unbudgeted (it is the frame).
    case frame
    /// The rest of a person's action that comes back after its turn (Chrome kUserBlocking, "affect
    /// the UI immediately after a user interaction"): a `.waiting` action's reply, the rollback of a
    /// person's failed command, a person-caused flush the input-response pass did not reach.
    /// Budgeted: it runs before visible, the input response it answers does not hold it (its commit
    /// closes that response), and it is capped at the visible + automation shares
    /// (``MainFrameBudget/Budgets/userBlocking``).
    case userBlocking
    /// Model changes that show on screen and that no action of the person caused: the daemon
    /// store's event batches, sidebar row patches, content presentation. Budgeted; yields to
    /// pending input.
    case visible
    /// Work an agent, the CLI, MCP or another process asked for (control-socket requests,
    /// automation input). Budgeted below visible updates, so the person's own typing and what it
    /// shows always win.
    case automation
    /// Best effort: work nobody sees this frame.
    case background
    /// Work that runs only when the main thread has nothing else to do (Chrome's idle tasks,
    /// `third_party/blink/renderer/platform/scheduler/common/idle_helper.h`): in a long idle period
    /// after 50 ms of quiet, or in a short one between a frame's render pass and the next vsync.
    /// Each task gets an ``IdleDeadline``. Not budgeted per frame; posted with
    /// ``MainWorkScheduler/postIdle(owner:maxDelay:node:file:line:_:)``.
    case idle

    public static func < (lhs: MainWorkClass, rhs: MainWorkClass) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether ``MainFrameBudget`` limits this class per frame (`userBlocking`, `visible`,
    /// `automation`, `background`; `idle` has a deadline per idle period instead).
    public var isBudgeted: Bool {
        switch self {
        case .userBlocking, .visible, .automation, .background: true
        case .input, .frame, .idle: false
        }
    }

    /// The budgeted classes, highest priority first: the order a frame runs them in.
    public static let budgeted: [MainWorkClass] = [.userBlocking, .visible, .automation, .background]

    public var description: String {
        switch self {
        case .input: "input"
        case .frame: "frame"
        case .userBlocking: "userBlocking"
        case .visible: "visible"
        case .automation: "automation"
        case .background: "background"
        case .idle: "idle"
        }
    }
}
