import AppKit
import Foundation

/// Preserves accepted paste commands in a bounded FIFO outside the main actor.
actor TerminalImageTransferPreparationService {
    typealias Operation = @Sendable (
        TerminalPastePreparationRequest
    ) -> TerminalPastePreparationResult
    typealias Cleanup = @Sendable (TerminalPastePreparationResult) -> Void
    typealias DeadlineSleep = @Sendable (Duration) async throws -> Void
    typealias FailureSignal = @MainActor @Sendable (
        TerminalPastePreparationFailure
    ) -> Void

    static let defaultDeadline: Duration = .seconds(5)
    static let defaultMaximumBlockingOperations = 2
    static let defaultMaximumQueuedJobs = 32

    private let deadline: Duration
    private let maximumBlockingOperations: Int
    private let maximumQueuedJobs: Int
    private let deadlineSleep: DeadlineSleep
    private let operation: Operation
    private let cleanup: Cleanup
    private let failureSignal: FailureSignal
    private let cleanupQueue: DispatchQueue
    private var activeJobID: UUID?
    private var runningJobs: [UUID: TerminalPastePreparationJob] = [:]
    private var queuedJobs: [TerminalPastePreparationJob] = []

    init(
        deadline: Duration = TerminalImageTransferPreparationService.defaultDeadline,
        maximumBlockingOperations: Int = TerminalImageTransferPreparationService
            .defaultMaximumBlockingOperations,
        maximumQueuedJobs: Int = TerminalImageTransferPreparationService
            .defaultMaximumQueuedJobs,
        deadlineSleep: @escaping DeadlineSleep = { duration in
            // Genuine request deadline; cancellation tears down the sleeper.
            try await ContinuousClock().sleep(for: duration)
        },
        operation: @escaping Operation = TerminalImageTransferPreparationService
            .prepareSynchronously,
        cleanup: @escaping Cleanup = TerminalImageTransferPreparationService
            .cleanupSynchronously,
        failureSignal: @escaping FailureSignal = { _ in NSSound.beep() }
    ) {
        self.deadline = deadline
        self.maximumBlockingOperations = max(1, maximumBlockingOperations)
        self.maximumQueuedJobs = max(0, maximumQueuedJobs)
        self.deadlineSleep = deadlineSleep
        self.operation = operation
        self.cleanup = cleanup
        self.failureSignal = failureSignal
        self.cleanupQueue = DispatchQueue(
            label: "com.cmuxterm.paste-preparation.cleanup",
            qos: .utility
        )
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

                let canStartImmediately = canStartNextJob
                guard canStartImmediately
                        || queuedJobs.count < maximumQueuedJobs else {
                    continuation.resume(returning: .failure(.queueFull))
                    return
                }

                var job = TerminalPastePreparationJob(
                    id: id,
                    request: request,
                    continuation: continuation,
                    deadlineTask: nil
                )
                job.deadlineTask = makeDeadlineTask(for: id)
                if canStartImmediately {
                    start(job)
                } else {
                    queuedJobs.append(job)
                }
            }
        } onCancel: {
            Task { await self.cancel(jobID: id) }
        }
    }

    private var canStartNextJob: Bool {
        activeJobID == nil
            && runningJobs.count < maximumBlockingOperations
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
        precondition(canStartNextJob)
        activeJobID = job.id
        runningJobs[job.id] = job

        let id = job.id
        let request = job.request
        let operation = self.operation
        let cleanup = self.cleanup
        // Each quarantinable job owns one serial legacy-I/O queue. The actor
        // caps in-flight queues, so stuck AppKit providers cannot grow threads.
        let blockingQueue = DispatchQueue(
            label: "com.cmuxterm.paste-preparation.\(id.uuidString)",
            qos: .userInitiated
        )
        blockingQueue.async { [weak self] in
            let result = operation(request)
            guard let self else {
                cleanup(result)
                return
            }
            Task {
                await self.finishRunningJob(id: id, result: result)
            }
        }
    }

    private func finishRunningJob(
        id: UUID,
        result: TerminalPastePreparationResult
    ) {
        guard var job = runningJobs.removeValue(forKey: id) else {
            discard(result)
            return
        }
        if activeJobID == id {
            activeJobID = nil
        }
        if job.continuation == nil {
            discard(result)
        } else {
            resume(&job, returning: .success(result))
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
        if let queuedIndex = queuedJobs.firstIndex(where: { $0.id == jobID }) {
            var job = queuedJobs.remove(at: queuedIndex)
            resume(&job, returning: .failure(failure))
            return
        }
        guard activeJobID == jobID,
              var job = runningJobs[jobID],
              job.continuation != nil else {
            return
        }

        resume(&job, returning: .failure(failure))
        runningJobs[jobID] = job
        activeJobID = nil
        startNextJobIfPossible()
    }

    private func startNextJobIfPossible() {
        guard canStartNextJob,
              !queuedJobs.isEmpty else {
            return
        }
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

    private func discard(_ result: TerminalPastePreparationResult) {
        let cleanup = self.cleanup
        cleanupQueue.async {
            cleanup(result)
        }
    }

    private func signalFailureIfNeeded(
        _ failure: TerminalPastePreparationFailure
    ) async {
        guard failure != .cancelled else { return }
        await failureSignal(failure)
    }

    private nonisolated static func prepareSynchronously(
        request: TerminalPastePreparationRequest
    ) -> TerminalPastePreparationResult {
        let readRequest = request.pasteboard
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(readRequest.pasteboardName)
        )
        guard pasteboard.changeCount == readRequest.changeCount else {
            return rejectedResult(for: request.destination)
        }

        let preparedContent = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: request.mode
        )
        guard pasteboard.changeCount == readRequest.changeCount else {
            preparedContent.cleanupTransferredTemporaryFiles()
            return rejectedResult(for: request.destination)
        }

        switch request.destination {
        case .terminal:
            return .terminal(preparedContent)
        case .composer:
            return .composer(
                TextBoxPastePreparationService().prepare(
                    preparedContent: preparedContent
                )
            )
        }
    }

    private nonisolated static func rejectedResult(
        for destination: TerminalPastePreparationDestination
    ) -> TerminalPastePreparationResult {
        switch destination {
        case .terminal:
            return .terminal(.reject)
        case .composer:
            return .composer(.reject)
        }
    }

    private nonisolated static func cleanupSynchronously(
        _ result: TerminalPastePreparationResult
    ) {
        result.cleanupTransferredTemporaryFiles()
    }
}
