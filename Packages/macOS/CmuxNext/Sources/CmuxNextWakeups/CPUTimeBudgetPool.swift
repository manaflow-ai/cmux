import Foundation

/// The CPU-time budget that hidden nodes' main-thread work is charged to
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section E). It is Blink's `CPUTimeBudgetPool`
/// (third_party/blink/renderer/platform/scheduler/common/throttling/cpu_time_budget_pool.h), the
/// pool that holds a background page's timers to 1 % of the CPU.
///
/// The balance refills at ``Limits/refillPerSecond`` (10 ms each second: 1 % of wall time) up to
/// ``Limits/maxBalance`` (100 ms). The run time of each hidden task is subtracted, so the balance can
/// go below zero. While it is below zero, hidden work waits for ``delayUntilAllowed(_:)``: the time
/// refill needs to bring it back to zero (Blink's `GetNextAllowedRunTime`). The caller re-arms on its
/// 1 s-aligned hidden wake (`MainDeadline` with `.whenHidden`, or the node's task queue), so the work
/// runs on the first aligned wake that has budget, and no wake is spent on a turn that cannot run.
/// The balance never goes below what refills in ``Limits/maxThrottlingDelay``, so one long task
/// holds hidden work back for no more than that (Blink's `max_throttling_delay`).
///
/// Visible work is not charged and never waits. Exempt work (a hidden node that played media in the
/// last 30 s or has a capture vote) is not charged and never waits, as Blink takes such a page's
/// queues out of the pool.
///
/// cmux differs from Blink in one point: there is ONE pool for the main thread, where Blink has one
/// per page. Every hidden node runs on cmux's one main thread, so 50 hidden workspaces share 1 % of
/// it, and do not take 1 % each.
///
/// ```swift
/// let hiddenBudget = CPUTimeBudgetPool()          // the composition root, once
/// // At a hidden node's aligned wake:
/// let wait = hiddenBudget.delayUntilAllowed(.hidden)
/// guard wait == .zero else { return deadline.schedule(after: wait) { drain() } }
/// hiddenBudget.run(.hidden) { task() }
/// ```
@MainActor
public final class CPUTimeBudgetPool {
    /// How a task's run is charged to the pool.
    public enum Charge: Sendable, Equatable {
        /// Work of a visible node: not charged, never waits.
        case visible
        /// Work of a hidden node with recent media or a capture vote: not charged, never waits.
        case exempt
        /// Work of a hidden node: charged, and waits while the balance is below zero.
        case hidden

        /// The charge of a node's work: `.visible` while the node shows, `.exempt` while it is
        /// hidden with media in the last 30 s or a capture vote, `.hidden` otherwise.
        public init(isVisible: Bool, mediaOrCapture: Bool) {
            self = isVisible ? .visible : mediaOrCapture ? .exempt : .hidden
        }
    }

    /// The pool's refill rate and bounds.
    public struct Limits: Sendable, Equatable {
        /// The budget added for each second of wall time (Blink's `cpu_percentage`; 10 ms = 1 %).
        /// Kept between 1 ns and 1 s.
        public var refillPerSecond: Duration
        /// The highest balance: what hidden work can spend at once after a long quiet period.
        public var maxBalance: Duration
        /// The longest that hidden work waits after one long task: the balance never goes below
        /// what refills in this time.
        public var maxThrottlingDelay: Duration

        /// - Parameters:
        ///   - refillPerSecond: Budget added for each second (default 10 ms: 1 % of wall time).
        ///   - maxBalance: The cap of the balance (default 100 ms).
        ///   - maxThrottlingDelay: The longest wait after one long task (default 60 s, Blink's
        ///     `kDefaultMaxBackgroundThrottlingDelay` in page_scheduler_impl.cc).
        public init(refillPerSecond: Duration = .milliseconds(10), maxBalance: Duration = .milliseconds(100),
                    maxThrottlingDelay: Duration = .seconds(60)) {
            self.refillPerSecond = refillPerSecond
            self.maxBalance = maxBalance
            self.maxThrottlingDelay = maxThrottlingDelay
        }
    }

    /// What the pool charged since it was made (debug.main_budget, the script-storm CPU check).
    public struct Stats: Sendable, Equatable {
        /// Hidden runs charged.
        public var hiddenRuns = 0
        /// The run time of all charged runs.
        public var charged: Duration = .zero

        /// No runs charged.
        public init() {}
    }

    public let limits: Limits
    public private(set) var stats = Stats()

    private static let second: UInt64 = 1_000_000_000
    /// The balance stays within ±2^61 ns (73 years), so its arithmetic never overflows.
    private static let bound: UInt64 = 1 << 61
    private let uptimeNanos: () -> UInt64
    /// Refill per second, in nanoseconds (1 ... 1 s).
    private let rate: UInt64
    private let maxNanos: Int64
    /// The lowest balance (zero or below).
    private let floorNanos: Int64
    private var balanceNanos: Int64
    /// The uptime the balance was last refilled to (Blink's `last_checkpoint_`).
    private var checkpoint: UInt64

    /// A pool that starts full.
    ///
    /// - Parameters:
    ///   - limits: The refill rate and bounds (default: 10 ms/s, 100 ms cap, 60 s longest wait).
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds, as ``MainFrameBudget``); tests
    ///     inject one they move.
    public init(limits: Limits = Limits(), uptimeNanos: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.limits = limits
        self.uptimeNanos = uptimeNanos
        let rate = min(max(MainFrameBudget.nanos(limits.refillPerSecond), 1), Self.second)
        self.rate = rate
        maxNanos = Int64(min(MainFrameBudget.nanos(limits.maxBalance), Self.bound))
        floorNanos = -Int64(min(Self.refill(MainFrameBudget.nanos(limits.maxThrottlingDelay), rate: rate), Self.bound))
        balanceNanos = maxNanos
        checkpoint = uptimeNanos()
    }

    /// The balance now, refilled to the clock's time. Below zero, hidden work waits.
    public var balance: Duration {
        advance()
        return .nanoseconds(balanceNanos)
    }

    /// True when work charged as `charge` may run now: visible and exempt work always may, hidden
    /// work while the balance is not below zero.
    public func mayRun(_ charge: Charge) -> Bool {
        delayUntilAllowed(charge) == .zero
    }

    /// How long work charged as `charge` waits before it may run: zero for visible and exempt work,
    /// and for hidden work while the balance is not below zero; otherwise the time refill needs to
    /// bring the balance back to zero. The caller runs it at the first aligned wake after that.
    public func delayUntilAllowed(_ charge: Charge) -> Duration {
        guard charge == .hidden else { return .zero }
        advance()
        guard balanceNanos < 0 else { return .zero }
        return .nanoseconds(Int64(clamping: Self.timeToRefill(UInt64(-balanceNanos), rate: rate)))
    }

    /// Runs `body` and charges its run time as `charge` (only `.hidden` is charged; the clock is not
    /// read for the others).
    public func run<T>(_ charge: Charge, _ body: () throws -> T) rethrows -> T {
        guard charge == .hidden else { return try body() }
        let start = uptimeNanos()
        defer {
            let end = uptimeNanos()
            record(.hidden, ran: .nanoseconds(Int64(clamping: end > start ? end - start : 0)))
        }
        return try body()
    }

    /// Charges a run of `ran` that was measured elsewhere (a task queue that times its tasks itself).
    /// Only `.hidden` is charged (Blink's `RecordTaskRunTime`).
    public func record(_ charge: Charge, ran: Duration) {
        guard charge == .hidden else { return }
        advance()
        let nanos = Int64(min(MainFrameBudget.nanos(max(ran, .zero)), Self.bound))
        balanceNanos = max(balanceNanos - nanos, floorNanos)
        stats.hiddenRuns += 1
        stats.charged += .nanoseconds(nanos)
    }

    /// Refills the balance for the time since the last checkpoint, up to the cap.
    private func advance() {
        let now = uptimeNanos()
        guard now > checkpoint else { return }
        let elapsed = now - checkpoint
        checkpoint = now
        guard balanceNanos < maxNanos else { return }
        // Both bounds are within ±2^61, so the deficit and the sum fit in Int64.
        let added = min(Self.refill(elapsed, rate: rate), UInt64(maxNanos - balanceNanos))
        balanceNanos += Int64(added)
    }

    /// The budget that `elapsed` nanoseconds add at `rate` nanoseconds per second, rounded down.
    /// Whole seconds and the remainder are multiplied apart, so the product never overflows.
    private static func refill(_ elapsed: UInt64, rate: UInt64) -> UInt64 {
        let (whole, overflow) = (elapsed / second).multipliedReportingOverflow(by: rate)
        guard !overflow else { return .max }
        let (sum, sumOverflow) = whole.addingReportingOverflow(elapsed % second * rate / second)
        return sumOverflow ? .max : sum
    }

    /// The nanoseconds `rate` needs to add `amount`, rounded up.
    private static func timeToRefill(_ amount: UInt64, rate: UInt64) -> UInt64 {
        let (whole, overflow) = (amount / rate).multipliedReportingOverflow(by: second)
        guard !overflow else { return .max }
        let part = (amount % rate * second + rate - 1) / rate
        let (sum, sumOverflow) = whole.addingReportingOverflow(part)
        return sumOverflow ? .max : sum
    }
}
