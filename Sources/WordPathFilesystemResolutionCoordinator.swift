import Foundation

/// Bounds command-path and restricted Browser filesystem work process-wide.
///
/// Mutable scheduling state is main-actor isolated. Click and hover probes share
/// one interactive lane. Correctness-critical Browser work has a separate,
/// fixed-width lane, coalesces per owner, and uses a bounded owner queue. Every
/// probe retains its own subprocess deadline, so unrelated work cannot consume
/// another navigation's filesystem budget.
@MainActor
final class WordPathFilesystemResolutionCoordinator {
    typealias Completion = @MainActor @Sendable () -> Void
    typealias Work = @Sendable () async -> Completion
    typealias Prepare = @MainActor @Sendable () -> Work?
    typealias Discarded = @MainActor @Sendable () -> Void
    typealias Job = (
        id: UUID,
        isUserInitiated: Bool,
        coalescingKey: UUID?,
        prepare: Prepare,
        discarded: Discarded
    )
    private typealias RunningCoalescedJob = (id: UUID, task: Task<Void, Never>)

    static let shared = WordPathFilesystemResolutionCoordinator()

    private static let maximumPendingClicks = 32

    private let minimumHoverInterval: DispatchTimeInterval
    private let maximumConcurrentCoalescedJobs: Int
    private let maximumPendingCoalescedOwners: Int
    private var runningID: UUID?
    private var runningTask: Task<Void, Never>?
    private var pendingClicks: [Job] = []
    private var runningCoalescedJobs: [UUID: RunningCoalescedJob] = [:]
    private var pendingCoalescedOrder: [UUID] = []
    private var pendingCoalescedHead = 0
    private var pendingCoalescedKeys = Set<UUID>()
    private var pendingCoalescedJobs: [UUID: Job] = [:]
    private var pendingCoalescedKeyByJobID: [UUID: UUID] = [:]
    private var pendingHover: Job?
    private var nextHoverStartDeadline = DispatchTime.now()
    private var hoverStartTimer: DispatchSourceTimer?

    init(
        minimumHoverInterval: DispatchTimeInterval = .milliseconds(100),
        maximumConcurrentCoalescedJobs: Int = 4,
        maximumPendingCoalescedOwners: Int = 128
    ) {
        self.minimumHoverInterval = minimumHoverInterval
        self.maximumConcurrentCoalescedJobs = max(1, maximumConcurrentCoalescedJobs)
        self.maximumPendingCoalescedOwners = max(0, maximumPendingCoalescedOwners)
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
            prepare: prepare,
            discarded: discarded
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

    /// Runs correctness-critical work independently from terminal interaction.
    /// Only the latest pending job for each owner is retained. Distinct owners
    /// remain FIFO, and capacity rejection receives an explicit recovery callback.
    func submitCoalesced(
        id: UUID,
        coalescingKey: UUID,
        work: @escaping Work,
        discarded: @escaping Discarded,
        rejected: @escaping Discarded
    ) {
        let job = Job(
            id: id,
            isUserInitiated: true,
            coalescingKey: coalescingKey,
            prepare: { work },
            discarded: discarded
        )

        if let running = runningCoalescedJobs[coalescingKey] {
            running.task.cancel()
            replacePendingCoalescedJob(job, for: coalescingKey)
            return
        }
        if pendingCoalescedJobs[coalescingKey] != nil {
            replacePendingCoalescedJob(job, for: coalescingKey)
            return
        }
        if runningCoalescedJobs.count < maximumConcurrentCoalescedJobs {
            startCoalesced(job)
            return
        }
        guard pendingCoalescedJobs.count < maximumPendingCoalescedOwners else {
            rejected()
            return
        }
        pendingCoalescedJobs[coalescingKey] = job
        pendingCoalescedKeyByJobID[id] = coalescingKey
        if pendingCoalescedKeys.insert(coalescingKey).inserted {
            pendingCoalescedOrder.append(coalescingKey)
        }
    }

    func cancelPending(id: UUID) {
        if runningID == id {
            runningTask?.cancel()
        }
        if let index = pendingClicks.firstIndex(where: { $0.id == id }) {
            pendingClicks.remove(at: index).discarded()
        }
        if let running = runningCoalescedJobs.first(where: { $0.value.id == id }) {
            running.value.task.cancel()
        }
        if let key = pendingCoalescedKeyByJobID.removeValue(forKey: id),
           pendingCoalescedJobs[key]?.id == id {
            pendingCoalescedJobs.removeValue(forKey: key)?.discarded()
        }
        if pendingHover?.id == id {
            let discarded = pendingHover?.discarded
            pendingHover = nil
            discarded?()
        }
        startNextIfPossible()
        startPendingCoalescedJobsIfPossible()
    }

    private func replacePendingCoalescedJob(_ job: Job, for key: UUID) {
        if let previous = pendingCoalescedJobs.updateValue(job, forKey: key) {
            pendingCoalescedKeyByJobID.removeValue(forKey: previous.id)
            previous.discarded()
        }
        pendingCoalescedKeyByJobID[job.id] = key
        guard runningCoalescedJobs[key] == nil,
              pendingCoalescedKeys.insert(key).inserted else {
            return
        }
        pendingCoalescedOrder.append(key)
    }

    private func start(_ job: Job) {
        cancelScheduledHoverStart()
        guard let work = job.prepare() else {
            job.discarded()
            startNextIfPossible()
            return
        }
        runningID = job.id
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
        runningTask = nil
        startNextIfPossible()
    }

    private func startCoalesced(_ job: Job) {
        guard let key = job.coalescingKey else {
            job.discarded()
            startPendingCoalescedJobsIfPossible()
            return
        }
        guard let work = job.prepare() else {
            job.discarded()
            startPendingCoalescedJobsIfPossible()
            return
        }
        let id = job.id
        let task = Task.detached(priority: .utility) { [weak self, id, key, work] in
            let completion = await work()
            await MainActor.run { [weak self, id, key, completion] in
                completion()
                self?.didFinishCoalesced(id: id, key: key)
            }
        }
        runningCoalescedJobs[key] = (id: id, task: task)
    }

    private func didFinishCoalesced(id: UUID, key: UUID) {
        guard runningCoalescedJobs[key]?.id == id else { return }
        runningCoalescedJobs.removeValue(forKey: key)

        if let replacement = pendingCoalescedJobs.removeValue(forKey: key) {
            pendingCoalescedKeyByJobID.removeValue(forKey: replacement.id)
            startCoalesced(replacement)
            return
        }
        startPendingCoalescedJobsIfPossible()
    }

    private func startNextIfPossible() {
        guard runningID == nil else { return }
        if !pendingClicks.isEmpty {
            let next = pendingClicks.removeFirst()
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

    private func startPendingCoalescedJobsIfPossible() {
        while runningCoalescedJobs.count < maximumConcurrentCoalescedJobs,
              pendingCoalescedHead < pendingCoalescedOrder.count {
            let key = pendingCoalescedOrder[pendingCoalescedHead]
            pendingCoalescedHead += 1
            pendingCoalescedKeys.remove(key)
            if let next = pendingCoalescedJobs.removeValue(forKey: key) {
                pendingCoalescedKeyByJobID.removeValue(forKey: next.id)
                compactPendingCoalescedOrderIfNeeded()
                startCoalesced(next)
            }
        }
        compactPendingCoalescedOrderIfNeeded()
    }

    private func compactPendingCoalescedOrderIfNeeded() {
        guard pendingCoalescedHead > 64,
              pendingCoalescedHead * 2 >= pendingCoalescedOrder.count else {
            return
        }
        pendingCoalescedOrder.removeFirst(pendingCoalescedHead)
        pendingCoalescedHead = 0
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
