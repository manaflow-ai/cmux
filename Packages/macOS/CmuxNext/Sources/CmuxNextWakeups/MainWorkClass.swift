/// The priority class of one piece of main-thread work (plans/cmux-next/main-thread-budget.md).
///
/// The main thread does input dispatch, the minimal mutation of visible state and the Core
/// Animation commit. Everything the app schedules there runs in one of these classes, ordered as
/// Chrome orders its UI thread (USER_BLOCKING, USER_VISIBLE, BEST_EFFORT): a person's input first,
/// then frame-locked work, then visible model updates, then automation, then background work, then
/// idle work. ``MainFrameBudget`` gives each budgeted class a per-frame budget and makes it yield
/// while input is pending; idle work runs only in the ``IdleScheduler``'s idle periods, with a
/// deadline instead of a share.
public enum MainWorkClass: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// A person's input, or an injected stand-in for it (`debug.key`): runs on the next main run
    /// loop turn, before any batch, never deferred. While input work is queued, every budgeted
    /// class yields.
    case input
    /// Work locked to the display frame: springs, autoscroll, frame probes, terminal frame holds.
    /// Runs every frame, unbudgeted (it is the frame).
    case frame
    /// Model changes that show on screen: the daemon store's event batches, sidebar row patches,
    /// content presentation. Budgeted; yields to pending input.
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

    /// Whether ``MainFrameBudget`` limits this class per frame (`visible`, `automation`, `background`;
    /// `idle` has a deadline per idle period instead).
    public var isBudgeted: Bool {
        switch self {
        case .visible, .automation, .background: true
        case .input, .frame, .idle: false
        }
    }

    /// The budgeted classes, highest priority first.
    public static let budgeted: [MainWorkClass] = [.visible, .automation, .background]

    public var description: String {
        switch self {
        case .input: "input"
        case .frame: "frame"
        case .visible: "visible"
        case .automation: "automation"
        case .background: "background"
        case .idle: "idle"
        }
    }
}

