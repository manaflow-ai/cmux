public import Darwin
public import Dispatch

/// The quality of service a child process starts at: the process-roles column of
/// plans/cmux-next/threading-model.md, after Chrome's `base::Process::SetPriority` levels
/// (base/process/process_mac.cc) and the QoS table of base/threading/platform_thread_apple.mm.
///
/// A child never starts at `.userInteractive`: that class is for the threads a frame waits for, and a child
/// spawned from such a thread would compete with typing and frames for its whole life.
///
/// | Child | QoS |
/// | --- | --- |
/// | daemon bridge, Chromium host | ``userInitiated`` |
/// | acpmux, agent shell, Computer Use helper | ``default`` |
/// | shell completion, crash watcher | ``utility`` |
public enum ChildProcessQoS: Sendable, CaseIterable {
    /// A person waits for what the child does right now (the daemon link, the visible page).
    case userInitiated
    /// The child's work shows soon (an agent's daemon, a command a person started).
    case `default`
    /// Nobody at the keyboard waits for it (a completion list, the crash watcher).
    case utility
    /// Nobody waits for it at all.
    case background

    /// The pthread QoS class of the child's main thread.
    public var qosClass: qos_class_t {
        switch self {
        case .userInitiated: QOS_CLASS_USER_INITIATED
        case .default: QOS_CLASS_DEFAULT
        case .utility: QOS_CLASS_UTILITY
        case .background: QOS_CLASS_BACKGROUND
        }
    }

    /// The GCD QoS of the work that spawns the child (``ChildSpawnQueue``).
    public var dispatchQoS: DispatchQoS {
        switch self {
        case .userInitiated: .userInitiated
        case .default: .default
        case .utility: .utility
        case .background: .background
        }
    }

    /// The process-wide ceiling `posix_spawnattr_set_qos_class_np` sets: that call accepts only utility,
    /// background and maintenance (libpthread's qos.c maps them to a QoS clamp and refuses the rest with
    /// `EINVAL`). Nil for the higher classes, whose child takes the QoS of the thread that spawns it.
    public var spawnClamp: qos_class_t? {
        switch self {
        case .userInitiated, .default: nil
        case .utility: QOS_CLASS_UTILITY
        case .background: QOS_CLASS_BACKGROUND
        }
    }
}
