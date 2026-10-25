/// One sleep per wake-up boundary for main-thread deadlines (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// section E): deadlines that snap to the same boundary share one sleep, so the process wakes once for all of them.
///
/// Chrome does the same in two places, and this type keeps both rules:
/// - Flexible delayed tasks run no sooner than their time and are snapped up to the next 8 ms tick
///   (`SequenceManagerImpl::AdjustWakeUp` in base/task/sequence_manager/sequence_manager_impl.cc, with
///   `kAlignWakeUps` and `kDefaultLeeway` from base/task/task_features.h).
/// - The wake-ups of a hidden frame are snapped up to 1 s (`WakeUpBudgetPool::GetNextAllowedWakeUp` in
///   third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc).
///
/// A precise deadline is never moved: it sleeps to its own instant with no tolerance. Aligned sleeps pass
/// ``leeway`` as their tolerance, so the OS can coalesce them with other timers too (Chrome's leeway).
/// Hidden and flexible deadlines that land on the same instant share one sleep.
///
/// `MainDeadline` chooses the alignment (it downgrades a precise delay of 36 ms or more to flexible, and
/// uses ``Alignment/hidden`` only while its node is hidden and not exempt); this type only buckets. An action
/// runs synchronously on the main actor at its boundary, in deadline order, so it should post its work, not
/// do it. The one instance lives at the composition root; an empty instance has no sleep and no wakeup.
///
/// ```swift
/// let wakeups = AlignedWakeups(owner: "MainDeadline")
/// let ticket = wakeups.schedule(owner: "Sidebar.hover", after: .milliseconds(300), alignment: .flexible) { show() }
/// wakeups.cancel(ticket)
/// ```
@MainActor
public final class AlignedWakeups {
    /// How a deadline is placed on the timeline.
    public nonisolated enum Alignment: Sendable, Hashable {
        /// At its own instant, with no tolerance.
        case precise
        /// No sooner than its time, snapped up to the next ``flexibleInterval`` boundary.
        case flexible
        /// No sooner than its time, snapped up to the next ``hiddenInterval`` boundary.
        case hidden
    }

    /// A scheduled deadline; pass it to ``cancel(_:)``.
    public nonisolated struct Ticket: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    /// The flexible boundary grid (Chrome's 8 ms `kAlignWakeUps` tick).
    public nonisolated static let flexibleInterval: Duration = .milliseconds(8)
    /// The hidden boundary grid (Chrome's 1 s hidden-frame wake-up alignment).
    public nonisolated static let hiddenInterval: Duration = .seconds(1)
    /// The tolerance an aligned sleep passes to the clock (Chrome's `kDefaultLeeway`).
    public nonisolated static let leeway: Duration = .milliseconds(8)

    /// One sleep: a boundary instant (an offset on ``timeline``) and whether it may be late by ``leeway``.
    private nonisolated struct Key: Hashable, Sendable {
        let boundary: Duration
        let exact: Bool
    }

    private struct Entry {
        let id: UInt64
        let owner: String
        let due: Duration
        let action: @MainActor () -> Void
    }

    private struct Bucket {
        var entries: [Entry] = []
        var sleep: Task<Void, Never>?
    }

    private let timeline: Timeline
    private let ledger: WakeupLedger
    private let alignedOwner: String
    private let preciseOwner: String
    private var buckets: [Key: Bucket] = [:]
    /// Where each pending ticket sleeps; a ticket missing here was cancelled or has fired.
    private var tickets: [UInt64: Key] = [:]
    private var nextID: UInt64 = 0

    /// - Parameters:
    ///   - owner: The ledger owner of the sleeps: a bucket's wakeup is recorded as `<owner>.aligned` or
    ///     `<owner>.precise`, with the earliest deadline's owner as the reason.
    ///   - clock: The clock the sleeps run on (tests inject a manual one).
    ///   - ledger: Where each wakeup is recorded, once per sleep.
    public init(owner: String, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared) {
        timeline = Timeline(clock)
        self.ledger = ledger
        alignedOwner = owner + ".aligned"
        preciseOwner = owner + ".precise"
    }

    /// The number of sleeps pending: one per boundary that has a deadline.
    public var sleepCount: Int { buckets.count }

    /// The number of deadlines pending.
    public var pendingCount: Int { tickets.count }

    /// Whether `ticket` is still pending.
    public func isPending(_ ticket: Ticket) -> Bool { tickets[ticket.id] != nil }

    /// Runs `action` once, no sooner than `delay` from now, at the boundary `alignment` gives.
    ///
    /// - Parameters:
    ///   - owner: Who asked; the reason of the ledger wakeup when this is the bucket's earliest deadline.
    ///   - delay: How long to wait at least (a negative delay counts as zero).
    ///   - alignment: How the deadline is placed.
    ///   - action: Runs on the main actor at the boundary; it should post its work.
    /// - Returns: The ticket that cancels it.
    @discardableResult
    public func schedule(owner: String, after delay: Duration, alignment: Alignment,
                         _ action: @escaping @MainActor () -> Void) -> Ticket {
        let due = timeline.now() + max(delay, .zero)
        let key = Key(boundary: alignment.boundary(of: due), exact: alignment == .precise)
        nextID &+= 1
        let entry = Entry(id: nextID, owner: owner, due: due, action: action)
        tickets[entry.id] = key
        var bucket = buckets.removeValue(forKey: key) ?? Bucket()
        bucket.entries.append(entry)
        if bucket.sleep == nil { bucket.sleep = startSleep(for: key) }
        buckets[key] = bucket
        return Ticket(id: entry.id)
    }

    /// Drops a pending deadline; the last one of a boundary cancels that boundary's sleep.
    public func cancel(_ ticket: Ticket) {
        guard let key = tickets.removeValue(forKey: ticket.id), var bucket = buckets.removeValue(forKey: key) else { return }
        bucket.entries.removeAll { $0.id == ticket.id }
        if bucket.entries.isEmpty {
            bucket.sleep?.cancel()
        } else {
            buckets[key] = bucket
        }
    }

    private func startSleep(for key: Key) -> Task<Void, Never> {
        let timeline = timeline
        let tolerance = key.exact ? Duration.zero : Self.leeway
        // task-owner: the bucket's sleep; cancelled with its last deadline, and it holds self weakly.
        return Task { [weak self] in
            do { try await timeline.sleep(key.boundary, tolerance) } catch { return }
            guard !Task.isCancelled else { return }
            self?.fire(key)
        }
    }

    private func fire(_ key: Key) {
        guard let bucket = buckets.removeValue(forKey: key) else { return }
        let entries = bucket.entries.sorted { ($0.due, $0.id) < ($1.due, $1.id) }
        ledger.record(key.exact ? preciseOwner : alignedOwner, reason: entries.first?.owner ?? "deadline")
        for entry in entries {
            // An earlier action of this bucket may have cancelled a later one.
            guard tickets.removeValue(forKey: entry.id) != nil else { continue }
            entry.action()
        }
    }
}

extension AlignedWakeups.Alignment {
    /// The instant a deadline due at `due` fires: `due` itself when precise, else the first grid boundary at or
    /// after it. Both are offsets from the instance's start; a deadline never fires before it is due.
    public func boundary(of due: Duration) -> Duration {
        let interval: Duration
        switch self {
        case .precise: return due
        case .flexible: interval = AlignedWakeups.flexibleInterval
        case .hidden: interval = AlignedWakeups.hiddenInterval
        }
        let step = interval.nanosecondsRoundedUp
        return .nanoseconds((due.nanosecondsRoundedUp + step - 1) / step * step)
    }
}

/// A clock seen as offsets from the moment the timeline was made, so a boundary is plain `Duration`
/// arithmetic on any injected clock.
private nonisolated struct Timeline: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (_ offset: Duration, _ tolerance: Duration) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { offset, tolerance in try await clock.sleep(until: origin.advanced(by: offset), tolerance: tolerance) }
    }
}

private extension Duration {
    /// The duration in nanoseconds, a fraction counted as one more, so a boundary is never early (offsets
    /// here are non-negative and far below Int64's 292 years).
    var nanosecondsRoundedUp: Int64 {
        let (seconds, attoseconds) = components
        let (nanoseconds, fraction) = attoseconds.quotientAndRemainder(dividingBy: 1_000_000_000)
        return seconds * 1_000_000_000 + nanoseconds + (fraction > 0 ? 1 : 0)
    }
}
