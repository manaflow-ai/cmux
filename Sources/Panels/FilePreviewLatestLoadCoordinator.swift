import Foundation

/// Runs one load at a time while retaining only the latest pending submission.
@MainActor
final class FilePreviewLatestLoadCoordinator<Output: Sendable> {
    private struct Request: Sendable {
        let load: @Sendable () async -> Output
        let completion: @MainActor @Sendable (Output) -> Void
        let finish: @Sendable () -> Void
    }

    private var state = FilePreviewLatestRequestState<Request>()
    private var activeTask: Task<Void, Never>?

    @discardableResult
    func submit(
        load: @escaping @Sendable () async -> Output,
        completion: @escaping @MainActor @Sendable (Output) -> Void
    ) -> Task<Void, Never> {
        let (completionStream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let request = Request(
            load: load,
            completion: completion,
            finish: { continuation.finish() }
        )
        let transition = state.submit(request)
        transition.superseded?.request.finish()
        if let submission = transition.start {
            start(submission)
        }
        return Task {
            for await _ in completionStream {}
        }
    }

    func cancel() {
        activeTask?.cancel()
        let cancellation = state.cancel()
        cancellation.active?.request.finish()
        cancellation.pending?.request.finish()
    }

    private func start(_ submission: FilePreviewLatestRequestState<Request>.Submission) {
        activeTask = Task { [weak self] in
            let output = await submission.request.load()
            guard let self else {
                submission.request.finish()
                return
            }
            complete(submission, output: output)
        }
    }

    private func complete(
        _ submission: FilePreviewLatestRequestState<Request>.Submission,
        output: Output
    ) {
        activeTask = nil
        let transition = state.complete(id: submission.id)
        if transition.shouldDeliver {
            submission.request.completion(output)
        }
        submission.request.finish()
        if let next = transition.next {
            start(next)
        }
    }
}
