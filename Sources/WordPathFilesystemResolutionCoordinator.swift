import Foundation

/// Bounds command-hover and command-click filesystem work process-wide.
///
/// Mutable scheduling state is main-actor isolated. At most one asynchronous,
/// deadline-bounded probe runs at a time, while the actor retains only the
/// newest pending click and hover jobs. Clicks run first.
@MainActor
final class WordPathFilesystemResolutionCoordinator {
    typealias Completion = @MainActor @Sendable () -> Void
    typealias Work = @Sendable () async -> Completion
    typealias Discarded = @MainActor @Sendable () -> Void
    typealias Job = (id: UUID, work: Work, discarded: Discarded)

    static let shared = WordPathFilesystemResolutionCoordinator()

    private var runningID: UUID?
    private var runningTask: Task<Void, Never>?
    private var pendingClick: Job?
    private var pendingHover: Job?

    func submit(
        id: UUID,
        isUserInitiated: Bool,
        work: @escaping Work,
        discarded: @escaping Discarded
    ) {
        let job = Job(id: id, work: work, discarded: discarded)
        guard runningID != nil else {
            start(job)
            return
        }

        if isUserInitiated {
            pendingClick?.discarded()
            pendingClick = job
        } else {
            pendingHover?.discarded()
            pendingHover = job
        }
    }

    func cancelPending(id: UUID) {
        if runningID == id {
            runningTask?.cancel()
        }
        if pendingClick?.id == id {
            let discarded = pendingClick?.discarded
            pendingClick = nil
            discarded?()
        }
        if pendingHover?.id == id {
            let discarded = pendingHover?.discarded
            pendingHover = nil
            discarded?()
        }
    }

    private func start(_ job: Job) {
        runningID = job.id
        let id = job.id
        let work = job.work
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

        if let next = pendingClick {
            pendingClick = nil
            start(next)
        } else if let next = pendingHover {
            pendingHover = nil
            start(next)
        }
    }
}
