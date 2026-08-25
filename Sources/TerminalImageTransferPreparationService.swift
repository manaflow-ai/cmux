import AppKit
import Foundation

/// Preserves accepted paste commands in a bounded FIFO outside the main actor.
/// Every accepted command has one admission-to-completion deadline, including
/// time spent waiting behind the active worker.
actor TerminalImageTransferPreparationService {
    /// Cancellation must return only after any owned work terminates and is
    /// reaped so the service's single-operation resource bound remains true.
    typealias Operation = @Sendable (
        TerminalPastePreparationRequest
    ) async throws -> TerminalPastePreparationResult
    typealias Cleanup = @Sendable (TerminalPastePreparationResult) -> Void
    typealias DeadlineSleep = @Sendable (Duration) async throws -> Void
    /// Observes requests only after the actor has accepted them into its lane.
    typealias AdmissionSignal = @Sendable (
        TerminalPastePreparationRequest
    ) -> Void
    typealias FailureSignal = @MainActor @Sendable (
        TerminalPastePreparationFailure
    ) -> Void

    static let defaultDeadline: Duration = .seconds(5)
    static let defaultMaximumQueuedJobs = 32

    private let deadline: Duration
    private let maximumQueuedJobs: Int
    private let deadlineSleep: DeadlineSleep
    private let admissionSignal: AdmissionSignal
    private let operation: Operation
    private let cleanup: Cleanup
    private let failureSignal: FailureSignal
    private var activeJob: TerminalPastePreparationJob?
    private var queuedJobs: [TerminalPastePreparationJob] = []

    init(
        deadline: Duration = TerminalImageTransferPreparationService
            .defaultDeadline,
        maximumQueuedJobs: Int = TerminalImageTransferPreparationService
            .defaultMaximumQueuedJobs,
        deadlineSleep: @escaping DeadlineSleep = { duration in
            // Genuine request deadline; cancellation tears down the sleeper.
            try await ContinuousClock().sleep(for: duration)
        },
        admissionSignal: @escaping AdmissionSignal = { _ in },
        operation: @escaping Operation,
        cleanup: @escaping Cleanup,
        failureSignal: @escaping FailureSignal = { _ in NSSound.beep() }
    ) {
        self.deadline = deadline
        self.maximumQueuedJobs = max(0, maximumQueuedJobs)
        self.deadlineSleep = deadlineSleep
        self.admissionSignal = admissionSignal
        self.operation = operation
        self.cleanup = cleanup
        self.failureSignal = failureSignal
    }

    nonisolated func cleanupTransferredTemporaryFiles(
        _ content: TerminalImageTransferPreparedContent
    ) {
        cleanup(.terminal(content))
    }

    nonisolated func cleanupTransferredTemporaryFiles(
        _ content: TextBoxPastePreparedContent
    ) {
        cleanup(.composer(content))
    }

    func prepare(
        request: TerminalPasteboardReadRequest,
        mode: TerminalImageTransferMode
    ) async -> TerminalImageTransferPreparedContent {
        let outcome = await submit(
            TerminalPastePreparationRequest(
                pasteboard: request,
                mode: mode,
                destination: .terminal
            )
        )
        switch outcome {
        case .success(.terminal(let content)):
            return content
        case .success:
            return .reject
        case .failure(let failure):
            await signalFailureIfNeeded(failure)
            return .reject
        }
    }

    func prepareComposer(
        request: TerminalPasteboardReadRequest
    ) async -> TextBoxPastePreparedContent {
        let outcome = await submit(
            TerminalPastePreparationRequest(
                pasteboard: request,
                mode: .paste,
                destination: .composer
            )
        )
        switch outcome {
        case .success(.composer(let content)):
            return content
        case .success:
            return .reject
        case .failure(let failure):
            await signalFailureIfNeeded(failure)
            return .reject
        }
    }

    private func submit(
        _ request: TerminalPastePreparationRequest
    ) async -> Result<
        TerminalPastePreparationResult,
        TerminalPastePreparationFailure
    > {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                guard activeJob == nil
                        || queuedJobs.count < maximumQueuedJobs else {
                    continuation.resume(returning: .failure(.queueFull))
                    return
                }

                let job = TerminalPastePreparationJob(
                    id: id,
                    request: request,
                    continuation: continuation,
                    deadlineTask: makeDeadlineTask(for: id),
                    operationTask: nil
                )
                if activeJob == nil {
                    start(job)
                } else {
                    queuedJobs.append(job)
                }
                admissionSignal(request)
            }
        } onCancel: {
            Task {
                await self.cancel(jobID: id)
            }
        }
    }

    private func makeDeadlineTask(for jobID: UUID) -> Task<Void, Never> {
        let deadline = self.deadline
        let deadlineSleep = self.deadlineSleep
        return Task { [weak self] in
            do {
                try await deadlineSleep(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expire(jobID: jobID)
        }
    }

    private func start(_ job: TerminalPastePreparationJob) {
        precondition(activeJob == nil)
        var runningJob = job
        let id = job.id
        let request = job.request
        let operation = self.operation
        let cleanup = self.cleanup
        runningJob.operationTask = Task { [weak self] in
            do {
                let result = try await operation(request)
                guard let self else {
                    cleanup(result)
                    return
                }
                await self.finish(jobID: id, result: result)
            } catch is CancellationError {
                await self?.finish(
                    jobID: id,
                    failure: .cancelled
                )
            } catch {
                await self?.finish(
                    jobID: id,
                    failure: .workerFailed
                )
            }
        }
        activeJob = runningJob
    }

    private func finish(
        jobID: UUID,
        result: TerminalPastePreparationResult
    ) {
        guard var job = activeJob, job.id == jobID else {
            cleanup(result)
            return
        }
        activeJob = nil
        if job.continuation == nil {
            cleanup(result)
        } else {
            resume(&job, returning: .success(result))
        }
        startNextJobIfPossible()
    }

    private func finish(
        jobID: UUID,
        failure: TerminalPastePreparationFailure
    ) {
        guard var job = activeJob, job.id == jobID else { return }
        activeJob = nil
        if job.continuation != nil {
            resume(&job, returning: .failure(failure))
        }
        startNextJobIfPossible()
    }

    private func cancel(jobID: UUID) {
        fail(jobID: jobID, with: .cancelled)
    }

    private func expire(jobID: UUID) {
        fail(jobID: jobID, with: .deadlineExceeded)
    }

    private func fail(
        jobID: UUID,
        with failure: TerminalPastePreparationFailure
    ) {
        if let queuedIndex = queuedJobs.firstIndex(
            where: { $0.id == jobID }
        ) {
            var job = queuedJobs.remove(at: queuedIndex)
            resume(&job, returning: .failure(failure))
            return
        }
        guard var job = activeJob,
              job.id == jobID,
              job.continuation != nil else {
            return
        }

        resume(&job, returning: .failure(failure))
        let operationTask = job.operationTask
        // Keep the lane occupied until cancellation finishes terminating and
        // reaping its worker; advancing sooner could overlap wedged workers.
        activeJob = job
        operationTask?.cancel()
    }

    private func startNextJobIfPossible() {
        guard activeJob == nil, !queuedJobs.isEmpty else { return }
        start(queuedJobs.removeFirst())
    }

    private func resume(
        _ job: inout TerminalPastePreparationJob,
        returning outcome: Result<
            TerminalPastePreparationResult,
            TerminalPastePreparationFailure
        >
    ) {
        job.deadlineTask?.cancel()
        job.deadlineTask = nil
        job.continuation?.resume(returning: outcome)
        job.continuation = nil
    }

    private func signalFailureIfNeeded(
        _ failure: TerminalPastePreparationFailure
    ) async {
        guard failure != .cancelled else { return }
        await failureSignal(failure)
    }
}
