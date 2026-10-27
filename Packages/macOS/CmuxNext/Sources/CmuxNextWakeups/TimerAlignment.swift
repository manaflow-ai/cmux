/// How a ``MainDeadline`` may move its wake-up (plans/cmux-next/chrome-parity/p06-scheduler.md, section E).
///
/// Each case resolves to an ``AlignedWakeups/Placement`` on the main thread's one ``MainWakeUpQueue``, whose grid is
/// `CLOCK_UPTIME_RAW` and whose windows are ``WakeLeeway``'s, so a ``MainDeadline`` shares its wakes with every other
/// main-thread deadline:
/// - ``precise``: exactly at the deadline (`subtle::DelayPolicy::kPrecise`, base/task/delay_policy.h). Only a delay
///   below ``DelayPolicy/maxPreciseDelay`` stays precise; a longer one is ``flexible`` (`MaybeOverrideDelayPolicy`).
/// - ``flexible`` (the default): no sooner than the deadline, in ``WakeLeeway``'s window: the next 8 ms boundary below
///   1 s (`kDefaultLeeway`, `kAlignWakeUps`), the whole uptime second with min(10%, 1 s) of leeway from 1 s on.
/// - ``whenHidden(_:)``: while the node is not visible, the first whole uptime second at or after the deadline
///   (``AlignedWakeups/Placement/hidden``; `kDefaultThrottledWakeUpInterval`, third_party/blink/renderer/platform/
///   scheduler/main_thread/page_scheduler_impl.h). A repeating or self-re-arming deadline whose node has been hidden
///   for 5 minutes at its due time joins its node's wake-up budget: one wake a minute for the whole node, or one
///   1 s-aligned wake when the node had none in the last minute (`kIntensiveThrottledWakeUpInterval`,
///   `WakeUpBudgetPool::AllowLowerAlignmentIfNoRecentWakeUp`). A node that played media in the last 30 s
///   (`kRecentAudioDelay`) is not aligned: it is ``flexible``. A capture vote that does not stay hidden makes the node
///   visible; a `stayHidden` one renders the node but keeps its timers aligned (its page still reads hidden).
///
/// A deadline a person or a request waits on is ``precise`` or ``flexible``, never ``whenHidden(_:)``.
public enum TimerAlignment: Sendable {
    /// Exactly at the deadline, no tolerance. A delay of 36 ms or more is ``flexible``.
    case precise
    /// No sooner than the deadline, in ``WakeLeeway``'s window. The default.
    case flexible
    /// Like ``flexible`` while `node` is visible; aligned to 1 s (60 s for a repeating deadline hidden 5 minutes)
    /// while it is not.
    case whenHidden(VisibilityNode)

    /// The grid of a repeating deadline hidden for ``intensiveAfter`` (`kIntensiveThrottledWakeUpInterval`).
    public static let intensiveGrid: Duration = .seconds(60)
    /// How long a node is hidden, at a repeating deadline's due time, before that deadline wakes once a minute
    /// (`kIntensiveWakeUpThrottling_GracePeriodSeconds_Default`).
    public static let intensiveAfter: Duration = .seconds(300)
    /// How recently a node may have played media and still be exempt from alignment (`kRecentAudioDelay`).
    public static let recentMedia: Duration = .seconds(30)

    /// The node of a ``whenHidden(_:)`` alignment.
    public var node: VisibilityNode? {
        if case .whenHidden(let node) = self { return node }
        return nil
    }

    /// The rule that applies to a deadline `delay` from now.
    ///
    /// - Parameters:
    ///   - delay: The time left until the deadline is due.
    ///   - repeating: The deadline repeats or re-armed itself from its own action.
    ///   - uptime: Now, on the clock of the node's tree (``VisibilityNode/hiddenSince``'s clock).
    @MainActor
    public func rule(delay: Duration, repeating: Bool, uptime: Duration) -> Wake.Rule {
        switch self {
        case .precise:
            return DelayPolicy.precise.effective(for: delay) == .precise ? .precise : .flexible
        case .flexible:
            return .flexible
        case .whenHidden(let node):
            guard !node.isVisible, !node.mediaActiveWithin(Self.recentMedia) else { return .flexible }
            guard repeating, let since = node.hiddenSince, uptime - since + max(delay, .zero) >= Self.intensiveAfter else {
                return .hidden
            }
            return .intensive
        }
    }

    /// Where one deadline wakes: its rule, when it is due, when it fires and how late the timer may fire for it.
    /// Instants are `CLOCK_UPTIME_RAW` time on the ``MainWakeUpQueue``'s clock.
    public struct Wake: Sendable, Equatable {
        /// Which alignment rule placed the wake.
        public enum Rule: Sendable, Equatable {
            /// At the due instant.
            case precise
            /// ``WakeLeeway``'s window after the due instant.
            case flexible
            /// The first whole uptime second at or after the due instant.
            case hidden
            /// The node's wake-up budget: once a minute, or at the next 1 s boundary when the node had no wake in
            /// the last minute.
            case intensive

            /// Where the rule puts a deadline on the queue; nil for ``intensive``, which the node's budget places.
            var placement: AlignedWakeups.Placement? {
                switch self {
                case .precise: .precise
                case .flexible: .flexible
                case .hidden: .hidden
                case .intensive: nil
                }
            }
        }

        /// The rule that placed it.
        public let rule: Rule
        /// When the deadline is due: it never fires before.
        public let due: Duration
        /// When it fires if nothing else moves its wake.
        public let fire: Duration
        /// How late after ``fire`` the timer may fire: the window's leeway (zero for ``Rule/precise``).
        public let tolerance: Duration

        init(rule: Rule, due: UInt64, fire: UInt64, tolerance: Duration) {
            self.rule = rule
            self.due = .nanoseconds(Int64(clamping: due))
            self.fire = .nanoseconds(Int64(clamping: fire))
            self.tolerance = tolerance
        }
    }

    /// The fire of the node's wake-up budget for its earliest deadline, due at `due` (uptime ns), when the node's
    /// last budget wake was at `lastWake`: `WakeUpBudgetPool::GetNextAllowedWakeUp` with a 60 s interval and a 1 s
    /// alignment when there was no wake in the last minute. That is the earlier of the next minute boundary at or
    /// after `due` and the first whole second at or after both `due` and a minute after the last wake. Both grids
    /// are on uptime, phase zero (`SnappedToNextTick(TimeTicks(), interval)`).
    static func intensiveFire(due: UInt64, lastWake: UInt64?) -> UInt64 {
        let second = WakeLeeway.wholeSecondDelay.nanosecondCount
        guard let lastWake else { return snap(due, to: second) }
        let minute = intensiveGrid.nanosecondCount
        let (afterBudget, overflow) = lastWake.addingReportingOverflow(minute)
        let aligned = snap(max(due, overflow ? .max : afterBudget), to: second)
        return min(aligned, snap(due, to: minute))
    }

    /// The first multiple of `step` at or after `instant` (uptime ns).
    private static func snap(_ instant: UInt64, to step: UInt64) -> UInt64 {
        let remainder = instant % step
        guard remainder != 0 else { return instant }
        let (snapped, overflow) = instant.addingReportingOverflow(step - remainder)
        return overflow ? .max : snapped
    }
}
