import Foundation

/// Bounds command-hover and command-click filesystem work process-wide.
///
/// Mutable scheduling state is main-actor isolated. A dedicated serial queue
/// runs at most one potentially blocking filesystem probe, while the actor
/// retains only the newest pending click and hover jobs. Clicks run first.
@MainActor
final class WordPathFilesystemResolutionCoordinator {
    typealias Completion = @MainActor @Sendable () -> Void
    typealias Work = @Sendable () -> Completion
    typealias Discarded = @MainActor @Sendable () -> Void
    typealias Job = (id: UUID, work: Work, discarded: Discarded)

    static let shared = WordPathFilesystemResolutionCoordinator()

    private let queue: DispatchQueue
    private var runningID: UUID?
    private var pendingClick: Job?
    private var pendingHover: Job?

    init(label: String = "com.cmux.word-path-filesystem-resolution") {
        queue = DispatchQueue(label: label, qos: .utility)
    }

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
        queue.async { [weak self, id, work] in
            let completion = work()
            Task { @MainActor [weak self, id, completion] in
                completion()
                self?.didFinish(id: id)
            }
        }
    }

    private func didFinish(id: UUID) {
        guard runningID == id else { return }
        runningID = nil

        if let next = pendingClick {
            pendingClick = nil
            start(next)
        } else if let next = pendingHover {
            pendingHover = nil
            start(next)
        }
    }
}
