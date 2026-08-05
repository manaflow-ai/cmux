import Foundation

/// Bounds command-path and restricted Browser filesystem work process-wide.
///
/// Mutable scheduling state is main-actor isolated. At most one asynchronous,
/// deadline-bounded probe runs at a time. Discrete clicks use a bounded FIFO,
/// correctness-critical Browser work coalesces per owner and expires after a
/// bounded queue wait, hover movement collapses to the newest request, and
/// hover starts are rate limited. Click and Browser work alternate while both
/// are pending, and either class runs before hover work.
@MainActor
final class WordPathFilesystemResolutionCoordinator {
    private enum ForegroundQueueTurn {
        case click
        case coalesced
    }

    typealias Completion = @MainActor @Sendable () -> Void
    typealias Work = @Sendable () async -> Completion
    typealias Prepare = @MainActor @Sendable () -> Work?
    typealias Discarded = @MainActor @Sendable () -> Void
    typealias Job = (
        id: UUID,
        isUserInitiated: Bool,
        coalescingKey: UUID?,
        queueDeadline: DispatchTime?,
        prepare: Prepare,
        discarded: Discarded,
        expired: Discarded?
    )

    static let shared = WordPathFilesystemResolutionCoordinator()

    private static let maximumPendingClicks = 32

    private let minimumHoverInterval: DispatchTimeInterval
    private let maximumCoalescedQueueWait: DispatchTimeInterval
    private var runningID: UUID?
    private var runningCoalescingKey: UUID?
    private var runningTask: Task<Void, Never>?
    private var pendingClicks: [Job] = []
    private var pendingCoalescedOrder: [UUID] = []
    private var pendingCoalescedHead = 0
    private var pendingCoalescedKeys = Set<UUID>()
    private var pendingCoalescedJobs: [UUID: Job] = [:]
    private var pendingCoalescedKeyByJobID: [UUID: UUID] = [:]
    private var foregroundQueueTurn: ForegroundQueueTurn = .coalesced
    private var coalescedExpiryTimer: DispatchSourceTimer?
    private var coalescedExpiryTimerDeadline: DispatchTime?
    private var pendingHover: Job?
    private var nextHoverStartDeadline = DispatchTime.now()
    private var hoverStartTimer: DispatchSourceTimer?

    init(
        minimumHoverInterval: DispatchTimeInterval = .milliseconds(100),
        // Browser work that cannot start within this budget enters its visible
        // recoverable-failure state instead of waiting behind every restored tab.
        maximumCoalescedQueueWait: DispatchTimeInterval = .seconds(1)
    ) {
        self.minimumHoverInterval = minimumHoverInterval
        self.maximumCoalescedQueueWait = maximumCoalescedQueueWait
    }

    func submit(
        id: UUID,
        isUserInitiated: Bool,
        work: @escaping Work,
        discarded: @escaping Discarded
    ) {
        submit(
            id: id,
            isUserInitiated: isUserInitiated,
            prepare: { work },
            discarded: discarded
        )
    }

    func submit(
        id: UUID,
        isUserInitiated: Bool,
        prepare: @escaping Prepare,
        discarded: @escaping Discarded
    ) {
        let job = Job(
            id: id,
            isUserInitiated: isUserInitiated,
            coalescingKey: nil,
            queueDeadline: nil,
            prepare: prepare,
            discarded: discarded,
            expired: nil
        )

        if isUserInitiated {
            if pendingClicks.count == Self.maximumPendingClicks {
                pendingClicks.removeFirst().discarded()
            }
            pendingClicks.append(job)
        } else {
            pendingHover?.discarded()
            pendingHover = job
        }
        startNextIfPossible()
    }

    /// Queues correctness-critical work without silently evicting an owner.
    /// Only the latest pending job for each owner is retained. Distinct owners
    /// remain FIFO, and expired owners receive an explicit recovery callback.
    func submitCoalesced(
        id: UUID,
        coalescingKey: UUID,
        work: @escaping Work,
        discarded: @escaping Discarded,
        expired: @escaping Discarded
    ) {
        let job = Job(
            id: id,
            isUserInitiated: true,
            coalescingKey: coalescingKey,
            queueDeadline: .now() + maximumCoalescedQueueWait,
            prepare: { work },
            discarded: discarded,
            expired: expired
        )
        if runningCoalescingKey == coalescingKey {
            runningTask?.cancel()
        }
        if let previous = pendingCoalescedJobs.updateValue(job, forKey: coalescingKey) {
            pendingCoalescedKeyByJobID.removeValue(forKey: previous.id)
            previous.discarded()
        }
        pendingCoalescedKeyByJobID[id] = coalescingKey
        if pendingCoalescedKeys.insert(coalescingKey).inserted {
            pendingCoalescedOrder.append(coalescingKey)
        }
        if let queueDeadline = job.queueDeadline {
            scheduleCoalescedExpiryTimerIfEarlier(at: queueDeadline)
        }
        startNextIfPossible()
    }

    func cancelPending(id: UUID) {
        if runningID == id {
            runningTask?.cancel()
        }
        if let index = pendingClicks.firstIndex(where: { $0.id == id }) {
            pendingClicks.remove(at: index).discarded()
        }
        if let key = pendingCoalescedKeyByJobID.removeValue(forKey: id),
           pendingCoalescedJobs[key]?.id == id {
            pendingCoalescedJobs.removeValue(forKey: key)?.discarded()
            rescheduleCoalescedExpiryTimer()
        }
        if pendingHover?.id == id {
            let discarded = pendingHover?.discarded
            pendingHover = nil
            discarded?()
        }
        startNextIfPossible()
    }

    private func start(_ job: Job) {
        cancelScheduledHoverStart()
        guard let work = job.prepare() else {
            job.discarded()
            startNextIfPossible()
            return
        }
        runningID = job.id
        runningCoalescingKey = job.coalescingKey
        if !job.isUserInitiated {
            nextHoverStartDeadline = .now() + minimumHoverInterval
        }
        let id = job.id
        runningTask = Task.detached(priority: .utility) { [weak self, id, work] in
            let completion = await work()
            await MainActor.run { [weak self, id, completion] in
                completion()
                self?.didFinish(id: id)
            }
        }
    }

    private func didFinish(id: UUID) {
        guard runningID == id else { return }
        runningID = nil
        runningCoalescingKey = nil
        runningTask = nil
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard runningID == nil else { return }
        let now = DispatchTime.now()
        if let coalescedExpiryTimerDeadline,
           now >= coalescedExpiryTimerDeadline {
            expirePendingCoalescedJobs(now: now)
        }

        if foregroundQueueTurn == .coalesced,
           let next = dequeueNextCoalescedJob() {
            foregroundQueueTurn = .click
            start(next)
            return
        }
        if !pendingClicks.isEmpty {
            let next = pendingClicks.removeFirst()
            foregroundQueueTurn = .coalesced
            start(next)
            return
        }
        if let next = dequeueNextCoalescedJob() {
            foregroundQueueTurn = .click
            start(next)
            return
        }

        guard let next = pendingHover else {
            cancelScheduledHoverStart()
            return
        }
        let now = DispatchTime.now()
        guard now >= nextHoverStartDeadline else {
            scheduleHoverStart(at: nextHoverStartDeadline)
            return
        }
        pendingHover = nil
        start(next)
    }

    private func dequeueNextCoalescedJob() -> Job? {
        while pendingCoalescedHead < pendingCoalescedOrder.count {
            let key = pendingCoalescedOrder[pendingCoalescedHead]
            pendingCoalescedHead += 1
            pendingCoalescedKeys.remove(key)
            if let next = pendingCoalescedJobs.removeValue(forKey: key) {
                pendingCoalescedKeyByJobID.removeValue(forKey: next.id)
                compactPendingCoalescedOrderIfNeeded()
                if let queueDeadline = next.queueDeadline,
                   DispatchTime.now() >= queueDeadline {
                    next.expired?()
                    continue
                }
                return next
            }
        }
        compactPendingCoalescedOrderIfNeeded()
        return nil
    }

    private func compactPendingCoalescedOrderIfNeeded() {
        guard pendingCoalescedHead > 64,
              pendingCoalescedHead * 2 >= pendingCoalescedOrder.count else {
            return
        }
        pendingCoalescedOrder.removeFirst(pendingCoalescedHead)
        pendingCoalescedHead = 0
    }

    private func scheduleCoalescedExpiryTimerIfEarlier(at deadline: DispatchTime) {
        if let coalescedExpiryTimerDeadline,
           coalescedExpiryTimerDeadline <= deadline {
            return
        }
        scheduleCoalescedExpiryTimer(at: deadline)
    }

    private func scheduleCoalescedExpiryTimer(at deadline: DispatchTime) {
        if let coalescedExpiryTimer {
            coalescedExpiryTimer.schedule(deadline: deadline)
        } else {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.coalescedExpiryTimerDidFire()
                }
            }
            coalescedExpiryTimer = timer
            timer.schedule(deadline: deadline)
            timer.resume()
        }
        coalescedExpiryTimerDeadline = deadline
    }

    private func coalescedExpiryTimerDidFire() {
        expirePendingCoalescedJobs(now: .now())
        startNextIfPossible()
    }

    private func expirePendingCoalescedJobs(now: DispatchTime) {
        let expiredKeys = pendingCoalescedJobs.compactMap { key, job -> UUID? in
            guard let queueDeadline = job.queueDeadline,
                  now >= queueDeadline else {
                return nil
            }
            return key
        }
        for key in expiredKeys {
            guard let job = pendingCoalescedJobs.removeValue(forKey: key) else { continue }
            pendingCoalescedKeyByJobID.removeValue(forKey: job.id)
            job.expired?()
        }
        rescheduleCoalescedExpiryTimer()
    }

    private func rescheduleCoalescedExpiryTimer() {
        let nextDeadline = pendingCoalescedJobs.values.compactMap { $0.queueDeadline }.min()
        guard let nextDeadline else {
            coalescedExpiryTimer?.cancel()
            coalescedExpiryTimer = nil
            coalescedExpiryTimerDeadline = nil
            return
        }
        scheduleCoalescedExpiryTimer(at: nextDeadline)
    }

    private func scheduleHoverStart(at deadline: DispatchTime) {
        if let hoverStartTimer {
            hoverStartTimer.schedule(deadline: deadline)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.hoverStartTimerDidFire()
            }
        }
        hoverStartTimer = timer
        timer.resume()
    }

    private func hoverStartTimerDidFire() {
        cancelScheduledHoverStart()
        startNextIfPossible()
    }

    private func cancelScheduledHoverStart() {
        hoverStartTimer?.cancel()
        hoverStartTimer = nil
    }
}
