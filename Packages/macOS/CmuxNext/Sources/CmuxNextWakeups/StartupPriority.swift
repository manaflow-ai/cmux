/// When a launch task runs, relative to the first frame and to startup completion
/// (plans/cmux-next/chrome-parity/p08-startup.md, sections 3A and 3B).
///
/// Chrome splits startup the same way: work the first window needs runs at once (the `kStartup`
/// queue, content/browser/scheduler/browser_task_queues.h), and work that only has to happen
/// eventually goes through `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc), which holds it until startup is complete. Every
/// task ``StartupScheduler`` runs states one of these on purpose; there is no default.
///
/// ```swift
/// startup.post(.afterStartup, "Updater.start", on: .lane(.system, .bestEffort)) { updater.check() }
/// ```
public enum StartupPriority: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// The first window needs it: it runs at once (inline on main, or submitted to its lane). Its name
    /// must be in the scheduler's critical allowlist; any other name still runs and is recorded as a
    /// violation.
    case critical
    /// Needed right after the first frame (the live window under the picture, the visible panes): held
    /// until ``StartupScheduler/firstFrameCommitted()``, then run in post order. On main at
    /// ``MainWorkClass/visible`` (budgeted per frame, behind pending input); on a lane at its
    /// ``WorkPriority``.
    case afterFirstFrame
    /// Not needed for the launch: held until startup completes, then released in post order. On main at
    /// ``MainWorkClass/background``, one task per frame and behind pending input; on a lane at its
    /// ``WorkPriority``.
    case afterStartup
    /// Built on first use, never at launch (a lazy service). Documentation only: a post at this
    /// priority is recorded as a violation and runs as ``afterStartup``.
    case onDemand

    public static func < (lhs: StartupPriority, rhs: StartupPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .critical: "critical"
        case .afterFirstFrame: "afterFirstFrame"
        case .afterStartup: "afterStartup"
        case .onDemand: "onDemand"
        }
    }
}
