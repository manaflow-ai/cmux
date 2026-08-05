import Foundation

/// Bounds command-path and restricted Browser filesystem work process-wide.
///
/// Mutable scheduling state is main-actor isolated. At most one asynchronous,
/// deadline-bounded probe runs at a time. Discrete clicks use a bounded FIFO,
/// hover movement collapses to the newest request, and hover starts are rate
/// limited. Clicks run first.
@MainActor
final class WordPathFilesystemResolutionCoordinator {
    typealias Completion = @MainActor @Sendable () -> Void
    typealias Work = @Sendable () async -> Completion
    typealias Prepare = @MainActor @Sendable () -> Work?
    typealias Discarded = @MainActor @Sendable () -> Void
    typealias Job = (
        id: UUID,
        isUserInitiated: Bool,
        prepare: Prepare,
        discarded: Discarded
    )

    static let shared = WordPathFilesystemResolutionCoordinator()

    private static let maximumPendingClicks = 32

    private let minimumHoverInterval: DispatchTimeInterval
    private var runningID: UUID?
    private var runningTask: Task<Void, Never>?
    private var pendingClicks: [Job] = []
    private var pendingHover: Job?
    private var nextHoverStartDeadline = DispatchTime.now()
    private var hoverStartTimer: DispatchSourceTimer?

    init(minimumHoverInterval: DispatchTimeInterval = .milliseconds(100)) {
        self.minimumHoverInterval = minimumHoverInterval
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

    func cancelPending(id: UUID) {
        if runningID == id {
            runningTask?.cancel()
        }
        if let index = pendingClicks.firstIndex(where: { $0.id == id }) {
            pendingClicks.remove(at: index).discarded()
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
