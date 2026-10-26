/// How a ``MainDeadline`` may move its wake-up (plans/cmux-next/chrome-parity/p06-scheduler.md, section E).
///
/// The three cases follow Chromium's timer rules:
/// - ``precise``: exactly at the deadline, as `subtle::DelayPolicy::kPrecise` (base/task/delay_policy.h). Only a
///   delay below ``DelayPolicy/maxPreciseDelay`` (36 ms, `kDefaultMaxPreciseDelay` in base/task/task_features.cc)
///   stays precise; a longer one is ``flexible``, as `MaybeOverrideDelayPolicy` does.
/// - ``flexible`` (the default): no sooner than the deadline, snapped up to the next 8 ms boundary and slept with an
///   8 ms tolerance (`kDefaultLeeway` and `kAlignWakeUps`, base/task/task_features.h).
/// - ``whenHidden(_:)``: while the node is not visible, snapped up to the next 1 s boundary
///   (`PageSchedulerImpl::kDefaultThrottledWakeUpInterval`, third_party/blink/renderer/platform/scheduler/main_thread/
///   page_scheduler_impl.h). A repeating or self-re-arming deadline whose node has been hidden for 5 minutes at its due
///   time wakes once a minute (`kIntensiveThrottledWakeUpInterval`, after
///   `kIntensiveWakeUpThrottling_GracePeriodSeconds_Default`), with one 1 s-aligned wake allowed when the node had no
///   wake in the last minute (`WakeUpBudgetPool::AllowLowerAlignmentIfNoRecentWakeUp`). A node that played media in the
///   last 30 s (`kRecentAudioDelay`) or holds a capture vote is not aligned: it is ``flexible``.
///
/// A deadline a person or a request waits on is ``precise`` or ``flexible``, never ``whenHidden(_:)``.
public enum TimerAlignment: Sendable {
    /// Exactly at the deadline, no tolerance. A delay of 36 ms or more is ``flexible``.
    case precise
    /// No sooner than the deadline, at most 8 ms after it. The default.
    case flexible
    /// Like ``flexible`` while `node` is visible; aligned to 1 s (60 s for a repeating deadline hidden 5 minutes)
    /// while it is not.
    case whenHidden(VisibilityNode)

    /// The flexible grid and the tolerance of every aligned sleep: Chromium's `kDefaultLeeway` (8 ms).
    public static let leeway: Duration = WakeLeeway.defaultAlignment
    /// The grid of a hidden node's deadlines (`kDefaultThrottledWakeUpInterval`).
    public static let hiddenGrid: Duration = .seconds(1)
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
    ///   - isCaptured: Whether a capture vote that does not stay hidden holds the node.
    @MainActor
    public func rule(delay: Duration, repeating: Bool, uptime: Duration,
                     isCaptured: @MainActor (VisibilityNode) -> Bool) -> Wake.Rule {
        switch self {
        case .precise:
            return delay < DelayPolicy.maxPreciseDelay ? .precise : .flexible
        case .flexible:
            return .flexible
        case .whenHidden(let node):
            guard !node.isVisible, !node.mediaActiveWithin(Self.recentMedia), !isCaptured(node) else { return .flexible }
            guard repeating, let since = node.hiddenSince, uptime - since + max(delay, .zero) >= Self.intensiveAfter else {
                return .hidden
            }
            return .intensive
        }
    }

    /// Where one deadline wakes: its rule, the instant it fires and the tolerance of its sleep. Instants are offsets
    /// on the ``MainDeadlineScheduler``'s timeline, so every grid is shared by all its deadlines.
    public struct Wake: Sendable, Equatable {
        /// Which alignment rule placed the wake.
        public enum Rule: Sendable, Equatable {
            /// At the due instant.
            case precise
            /// The next 8 ms boundary at or after the due instant.
            case flexible
            /// The next 1 s boundary at or after the due instant.
            case hidden
            /// Once a minute, or at the next 1 s boundary when the node had no wake in the last minute.
            case intensive
        }

        /// The rule that placed it.
        public let rule: Rule
        /// When the deadline is due: it never fires before.
        public let due: Duration
        /// When it fires.
        public let fire: Duration
        /// How late the sleep may wake: zero for ``Rule/precise``, ``TimerAlignment/leeway`` otherwise.
        public let tolerance: Duration

        /// The wake of a deadline due at `due` under `rule`.
        ///
        /// - Parameters:
        ///   - rule: The rule (``TimerAlignment/rule(delay:repeating:uptime:isCaptured:)``).
        ///   - due: The due instant (a non-negative timeline offset).
        ///   - lastIntensiveWake: The node's last wake under ``Rule/intensive``; nil when it had none. Only that rule
        ///     reads it.
        public init(rule: Rule, due: Duration, lastIntensiveWake: Duration? = nil) {
            self.rule = rule
            self.due = max(due, .zero)
            tolerance = rule == .precise ? .zero : TimerAlignment.leeway
            switch rule {
            case .precise:
                fire = self.due
            case .flexible:
                fire = Self.snap(self.due, to: TimerAlignment.leeway)
            case .hidden:
                fire = Self.snap(self.due, to: TimerAlignment.hiddenGrid)
            case .intensive:
                fire = Self.intensiveFire(due: self.due, lastWake: lastIntensiveWake)
            }
        }

        /// `WakeUpBudgetPool::GetNextAllowedRunTime` with a 60 s interval and a 1 s alignment when there was no
        /// recent wake: the earlier of the next minute boundary and the first 1 s boundary a minute after the last wake.
        private static func intensiveFire(due: Duration, lastWake: Duration?) -> Duration {
            guard let lastWake else { return snap(due, to: TimerAlignment.hiddenGrid) }
            let aligned = snap(max(due, lastWake + TimerAlignment.intensiveGrid), to: TimerAlignment.hiddenGrid)
            return min(aligned, snap(due, to: TimerAlignment.intensiveGrid))
        }

        /// The first multiple of `grid` at or after `instant` (`TimeTicks::SnappedToNextTick`); a fraction of a
        /// nanosecond counts as one more, so a wake is never early.
        static func snap(_ instant: Duration, to grid: Duration) -> Duration {
            let step = grid.nanosecondCount
            guard step > 0 else { return instant }
            let whole = instant.nanosecondCount
            let value = Duration.nanoseconds(Int64(clamping: whole)) < instant ? whole + 1 : whole
            let remainder = value % step
            let snapped = remainder == 0 ? value : value + (step - remainder)
            return .nanoseconds(Int64(clamping: snapped))
        }
    }
}
