import AppKit
import Foundation

/// Bounds terminal and composer paste preparation to one legacy blocking lane.
actor TerminalImageTransferPreparationService {
    typealias Operation = @Sendable (
        TerminalPastePreparationRequest
    ) -> TerminalPastePreparationResult
    typealias Cleanup = @Sendable (TerminalPastePreparationResult) -> Void
    typealias DeadlineSleep = @Sendable (Duration) async throws -> Void

    static let defaultDeadline: Duration = .seconds(5)

    // A dedicated serial queue keeps blocking AppKit providers off Swift's
    // cooperative executor; actor isolation, not this queue, protects state.
    private nonisolated let blockingQueue: DispatchQueue
    private let deadline: Duration
    private let deadlineSleep: DeadlineSleep
    private let operation: Operation
    private let cleanup: Cleanup
    private var runningJob: TerminalPastePreparationJob?
    private var pendingJob: TerminalPastePreparationJob?

    init(
        deadline: Duration = TerminalImageTransferPreparationService.defaultDeadline,
        blockingQueue: DispatchQueue = DispatchQueue(
            label: "com.cmuxterm.paste-preparation",
            qos: .userInitiated
        ),
        deadlineSleep: @escaping DeadlineSleep = { duration in
            // Genuine request deadline; cancellation tears down the sleeper.
            try await ContinuousClock().sleep(for: duration)
        },
        operation: @escaping Operation = TerminalImageTransferPreparationService
            .prepareSynchronously,
        cleanup: @escaping Cleanup = TerminalImageTransferPreparationService
            .cleanupSynchronously
    ) {
        self.deadline = deadline
        self.blockingQueue = blockingQueue
        self.deadlineSleep = deadlineSleep
        self.operation = operation
        self.cleanup = cleanup
    }

    func prepare(
        request: TerminalPasteboardReadRequest,
        mode: TerminalImageTransferMode
    ) async -> TerminalImageTransferPreparedContent {
        let result = await submit(
            TerminalPastePreparationRequest(
                pasteboard: request,
                mode: mode,
                destination: .terminal
            )
        )
        guard case .terminal(let content)? = result else { return .reject }
        return content
    }

    func prepareComposer(
        request: TerminalPasteboardReadRequest
    ) async -> TextBoxPastePreparedContent {
        let result = await submit(
            TerminalPastePreparationRequest(
                pasteboard: request,
                mode: .paste,
                destination: .composer
            )
        )
        guard case .composer(let content)? = result else { return .reject }
        return content
    }

    private func submit(
        _ request: TerminalPastePreparationRequest
    ) async -> TerminalPastePreparationResult? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }

                var job = TerminalPastePreparationJob(
                    id: id,
                    request: request,
                    continuation: continuation,
                    deadlineTask: nil
                )
                job.deadlineTask = makeDeadlineTask(for: id)

                guard runningJob != nil else {
                    runningJob = job
                    startRunningJob()
                    return
                }

                if var supersededJob = pendingJob {
                    resume(&supersededJob, returning: nil)
                }
                pendingJob = job
            }
        } onCancel: {
            Task { await self.cancel(jobID: id) }
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

    private func startRunningJob() {
        guard let runningJob else { return }
        let id = runningJob.id
        let request = runningJob.request
        let operation = self.operation
        let cleanup = self.cleanup
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
        guard var job = runningJob,
              job.id == id else {
            discard(result)
            return
        }
        runningJob = nil
        if job.continuation == nil {
            discard(result)
        } else {
            resume(&job, returning: result)
        }

        if let nextJob = pendingJob {
            pendingJob = nil
            runningJob = nextJob
            startRunningJob()
        }
    }

    private func cancel(jobID: UUID) {
        if var job = pendingJob,
           job.id == jobID {
            pendingJob = nil
            resume(&job, returning: nil)
            return
        }
        if var job = runningJob,
           job.id == jobID {
            resume(&job, returning: nil)
            runningJob = job
        }
    }

    private func expire(jobID: UUID) {
        cancel(jobID: jobID)
    }

    private func resume(
        _ job: inout TerminalPastePreparationJob,
        returning result: TerminalPastePreparationResult?
    ) {
        job.deadlineTask?.cancel()
        job.deadlineTask = nil
        job.continuation?.resume(returning: result)
        job.continuation = nil
    }

    private func discard(_ result: TerminalPastePreparationResult) {
        let cleanup = self.cleanup
        blockingQueue.async {
            cleanup(result)
        }
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
