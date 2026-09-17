internal import CmuxTerminalBackend
internal import Foundation

/// Bounded, single-writer lane for renderer frame-release messages.
///
/// GPU completion callbacks enqueue without creating a task. One lifetime worker
/// serializes every accepted release, while a separate recovery quota guarantees
/// that receiver teardown can return frames even when ordinary completions fill
/// their quota.
final class BackendOnlyRendererFrameReleaseLane: Sendable {
    typealias Send = @Sendable (BackendRendererFrameRelease) async -> Bool
    typealias FailureHandler = @Sendable (
        BackendOnlyRendererFrameReleaseLaneFailure
    ) -> Void

    private let core: BackendOnlyRendererFrameReleaseCore
    private let workerTask: Task<Void, Never>

    init(
        normalCapacity: Int,
        recoveryCapacity: Int,
        send: @escaping Send,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        precondition(normalCapacity > 0)
        precondition(recoveryCapacity > 0)
        let signal = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let core = BackendOnlyRendererFrameReleaseCore(
            normalCapacity: normalCapacity,
            recoveryCapacity: recoveryCapacity,
            signal: signal.continuation,
            send: send,
            onFailure: onFailure
        )
        self.core = core
        workerTask = Task.detached(priority: .utility) {
            await core.run(signals: signal.stream)
        }
    }

    deinit {
        core.requestStop()
    }

    func enqueue(
        _ release: BackendRendererFrameRelease,
        priority: BackendOnlyRendererFrameReleasePriority
    ) -> BackendOnlyRendererFrameReleaseEnqueueResult {
        core.enqueue(release, priority: priority)
    }

    func metrics() -> BackendOnlyRendererFrameReleaseLaneMetrics {
        core.metrics()
    }

    func waitUntilIdle() async {
        await core.waitUntilIdle()
    }

    func stop() async {
        core.requestStop()
        await workerTask.value
    }
}
