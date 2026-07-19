internal import CmuxTerminalRenderProtocol
internal import CmuxTerminalRenderTransport
internal import Dispatch
internal import Foundation
internal import Metal

/// Owns the compositor's one-active, one-pending Metal submission mailbox.
///
/// The lock performs only fixed-size admission and completion bookkeeping.
/// Drawable acquisition, IOSurface texture import, and Metal calls execute on
/// `TerminalRenderMetalExecutor`. A single scheduled drain services all state
/// changes, so frame bursts cannot enqueue a task or queue block per frame.
final class TerminalRenderMetalBlitter: @unchecked Sendable {
    private struct Work: @unchecked Sendable {
        let id: UInt64
        let frame: TerminalRenderFrame
        let epoch: UInt64
        let layer: TerminalRenderMetalLayerHandle
        let continuation: CheckedContinuation<
            TerminalRenderCompositorEnqueueResult,
            Never
        >?

        var withoutContinuation: Work {
            Work(
                id: id,
                frame: frame,
                epoch: epoch,
                layer: layer,
                continuation: nil
            )
        }
    }

    private enum ActivePhase: Equatable {
        case queued
        case submitting
        case gpuInFlight
    }

    private struct Active {
        var work: Work
        var phase: ActivePhase
        var completionArrivedWhileSubmitting = false
    }

    private struct State {
        var currentEpoch: UInt64
        var currentLayer: TerminalRenderMetalLayerHandle
        var nextWorkID: UInt64 = 1
        var active: Active?
        var pending: Work?
        var outstandingFrameLeaseCount = 0
        var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
        var highestPresentedFrameSequence: UInt64?
        var cacheInvalidationPending = false
        var drainScheduled = false
        var stopped = false
        var metrics = TerminalRenderCompositorMetrics()
    }

    private enum ExecutorAction {
        case invalidateCache
        case submit(Work)
    }

    private let lock = NSLock()
    private var state: State
    private let executor: TerminalRenderMetalExecutor
    private let submissionBackend: any TerminalRenderMetalSubmitting
    private let releaseHandler: @Sendable (TerminalRenderFrameRelease) -> Void
    private let dispositionHandler: TerminalRenderFrameDispositionHandler?
    private let metricEventHandler: TerminalRenderCompositorMetricEventHandler?
    private let presentedHandler: TerminalRenderFramePresentedHandler?

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        initialEpoch: UInt64,
        initialLayer: TerminalRenderMetalLayerHandle,
        releaseHandler: @escaping @Sendable (TerminalRenderFrameRelease) -> Void,
        dispositionHandler: TerminalRenderFrameDispositionHandler?,
        metricEventHandler: TerminalRenderCompositorMetricEventHandler?,
        presentedHandler: TerminalRenderFramePresentedHandler?
    ) {
        self.executor = TerminalRenderMetalExecutor()
        self.submissionBackend = TerminalRenderMetalSubmissionBackend(
            device: device,
            commandQueue: commandQueue
        )
        self.state = State(
            currentEpoch: initialEpoch,
            currentLayer: initialLayer
        )
        self.releaseHandler = releaseHandler
        self.dispositionHandler = dispositionHandler
        self.metricEventHandler = metricEventHandler
        self.presentedHandler = presentedHandler
    }

    init(
        executor: TerminalRenderMetalExecutor,
        submissionBackend: any TerminalRenderMetalSubmitting,
        initialEpoch: UInt64,
        initialLayer: TerminalRenderMetalLayerHandle,
        releaseHandler: @escaping @Sendable (TerminalRenderFrameRelease) -> Void,
        dispositionHandler: TerminalRenderFrameDispositionHandler?,
        metricEventHandler: TerminalRenderCompositorMetricEventHandler?,
        presentedHandler: TerminalRenderFramePresentedHandler?
    ) {
        self.executor = executor
        self.submissionBackend = submissionBackend
        self.state = State(
            currentEpoch: initialEpoch,
            currentLayer: initialLayer
        )
        self.releaseHandler = releaseHandler
        self.dispositionHandler = dispositionHandler
        self.metricEventHandler = metricEventHandler
        self.presentedHandler = presentedHandler
    }

    func register(
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        var pendingToRelease: TerminalRenderFrame?
        var queuedToReject: Work?

        lock.lock()
        guard !state.stopped,
              epoch >= state.currentEpoch,
              epoch > state.currentEpoch || layer !== state.currentLayer else {
            lock.unlock()
            return
        }

        state.currentEpoch = epoch
        state.currentLayer = layer
        state.highestPresentedFrameSequence = nil
        state.cacheInvalidationPending = true
        pendingToRelease = state.pending?.frame
        state.pending = nil
        if let active = state.active, active.phase == .queued {
            queuedToReject = active.work
            state.active = nil
            state.metrics.rejectedFrames &+= 1
        }
        scheduleDrainLocked()
        lock.unlock()

        if let pendingToRelease {
            release(pendingToRelease)
        }
        if let queuedToReject {
            let result = TerminalRenderCompositorEnqueueResult.rejected(
                .presentationGenerationMismatch
            )
            metricEventHandler?(.rejectedFrame)
            record(queuedToReject.frame, result: result)
            release(queuedToReject.frame)
            queuedToReject.continuation?.resume(returning: result)
        }
    }

    func enqueue(
        _ frame: TerminalRenderFrame,
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) async -> TerminalRenderCompositorEnqueueResult {
        // Close the publication race between the ingress fence and this
        // mailbox. A newer frame can install its monotonic layer epoch here;
        // an older frame can never move the executor backwards.
        register(epoch: epoch, layer: layer)
        await withCheckedContinuation { continuation in
            admit(
                frame,
                epoch: epoch,
                layer: layer,
                continuation: continuation
            )
        }
    }

    func retry(
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        lock.lock()
        guard !state.stopped,
              epoch == state.currentEpoch,
              layer === state.currentLayer,
              state.active == nil,
              let pending = state.pending else {
            lock.unlock()
            return
        }
        state.pending = nil
        state.active = Active(work: pending, phase: .queued)
        scheduleDrainLocked()
        lock.unlock()
    }

    func metrics() -> TerminalRenderCompositorMetrics {
        lock.lock()
        defer { lock.unlock() }
        return state.metrics
    }

    var outstandingFrameLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.outstandingFrameLeaseCount
    }

    var quiescenceWaiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.quiescenceWaiters.count
    }

    /// Stops new submissions and returns only after every accepted frame's
    /// release callback has completed, including an active GPU read.
    func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            lock.lock()
            if state.outstandingFrameLeaseCount == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                state.quiescenceWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func stop() {
        var pendingToRelease: TerminalRenderFrame?
        var queuedToReject: Work?

        lock.lock()
        guard !state.stopped else {
            lock.unlock()
            return
        }
        state.stopped = true
        state.cacheInvalidationPending = true
        pendingToRelease = state.pending?.frame
        state.pending = nil
        if let active = state.active, active.phase == .queued {
            queuedToReject = active.work
            state.active = nil
            state.metrics.rejectedFrames &+= 1
            state.metrics.metalUnavailableFrames &+= 1
        }
        scheduleDrainLocked()
        lock.unlock()

        if let pendingToRelease {
            release(pendingToRelease)
        }
        if let queuedToReject {
            metricEventHandler?(.rejectedFrame)
            metricEventHandler?(.metalUnavailable)
            record(queuedToReject.frame, result: .metalUnavailable)
            release(queuedToReject.frame)
            queuedToReject.continuation?.resume(returning: .metalUnavailable)
        }
    }

    private func admit(
        _ frame: TerminalRenderFrame,
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle,
        continuation: CheckedContinuation<
            TerminalRenderCompositorEnqueueResult,
            Never
        >
    ) {
        var immediateResult: TerminalRenderCompositorEnqueueResult?
        var supersededFrame: TerminalRenderFrame?
        var incrementCoalescedMetric = false

        lock.lock()
        precondition(state.outstandingFrameLeaseCount < Int.max)
        state.outstandingFrameLeaseCount += 1
        if state.stopped {
            state.metrics.rejectedFrames &+= 1
            state.metrics.metalUnavailableFrames &+= 1
            immediateResult = .metalUnavailable
        } else if epoch != state.currentEpoch || layer !== state.currentLayer {
            state.metrics.rejectedFrames &+= 1
            immediateResult = .rejected(.presentationGenerationMismatch)
        } else if state.active != nil {
            let work = makeWorkLocked(
                frame: frame,
                epoch: epoch,
                layer: layer,
                continuation: nil
            )
            if let prior = state.pending {
                supersededFrame = prior.frame
                state.metrics.coalescedFrames &+= 1
                incrementCoalescedMetric = true
            }
            state.pending = work
            immediateResult = .coalesced
        } else {
            if let prior = state.pending {
                supersededFrame = prior.frame
                state.pending = nil
                state.metrics.coalescedFrames &+= 1
                incrementCoalescedMetric = true
            }
            let work = makeWorkLocked(
                frame: frame,
                epoch: epoch,
                layer: layer,
                continuation: continuation
            )
            state.active = Active(work: work, phase: .queued)
            scheduleDrainLocked()
        }
        lock.unlock()

        if incrementCoalescedMetric {
            metricEventHandler?(.coalescedFrame)
        }
        if let supersededFrame {
            release(supersededFrame)
        }
        if let immediateResult {
            if immediateResult == .metalUnavailable {
                metricEventHandler?(.rejectedFrame)
                metricEventHandler?(.metalUnavailable)
            } else if case .rejected = immediateResult {
                metricEventHandler?(.rejectedFrame)
            }
            record(frame, result: immediateResult)
            if immediateResult == .metalUnavailable {
                release(frame)
            } else if case .rejected = immediateResult {
                release(frame)
            }
            continuation.resume(returning: immediateResult)
        }
    }

    private func makeWorkLocked(
        frame: TerminalRenderFrame,
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle,
        continuation: CheckedContinuation<
            TerminalRenderCompositorEnqueueResult,
            Never
        >?
    ) -> Work {
        let id = state.nextWorkID
        state.nextWorkID &+= 1
        if state.nextWorkID == 0 {
            state.nextWorkID = 1
        }
        return Work(
            id: id,
            frame: frame,
            epoch: epoch,
            layer: layer,
            continuation: continuation
        )
    }

    private func scheduleDrainLocked() {
        guard !state.drainScheduled else { return }
        state.drainScheduled = true
        executor.enqueue { [self] in
            drainExecutor()
        }
    }

    private func drainExecutor() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        precondition(executor.isCurrentExecutor)

        while let action = nextExecutorAction() {
            switch action {
            case .invalidateCache:
                submissionBackend.invalidateSourceTextureCache()
            case .submit(let work):
                submit(work)
            }
        }
    }

    private func nextExecutorAction() -> ExecutorAction? {
        lock.lock()
        defer { lock.unlock() }
        if state.cacheInvalidationPending {
            state.cacheInvalidationPending = false
            return .invalidateCache
        }
        if var active = state.active, active.phase == .queued {
            active.phase = .submitting
            state.active = active
            return .submit(active.work)
        }
        state.drainScheduled = false
        return nil
    }

    private func submit(_ work: Work) {
        let fallbackRelease = releaseHandler
        let fallbackReleaseRecord = TerminalRenderFrameRelease(frame: work.frame)
        let callbacks = TerminalRenderMetalSubmissionCallbacks(
            completed: { [weak self] in
                guard let self else {
                    fallbackRelease(fallbackReleaseRecord)
                    return
                }
                self.submissionCompleted(workID: work.id)
            },
            presented: { [weak self] in
                self?.submissionPresented(
                    workID: work.id,
                    metadata: work.frame.metadata,
                    epoch: work.epoch,
                    layer: work.layer
                )
            }
        )
        let result = submissionBackend.submitOneFullSurfaceBlit(
            frame: work.frame,
            layer: work.layer,
            callbacks: callbacks
        )
        finishSubmissionAttempt(workID: work.id, backendResult: result)
    }

    private func finishSubmissionAttempt(
        workID: UInt64,
        backendResult: TerminalRenderMetalBackendSubmissionResult
    ) {
        var work: Work?
        var result: TerminalRenderCompositorEnqueueResult?
        var shouldRelease = false
        var completedImmediately = false
        var coalescedByNewerFrame = false

        lock.lock()
        guard var active = state.active,
              active.work.id == workID,
              active.phase == .submitting else {
            lock.unlock()
            return
        }
        work = active.work
        switch backendResult {
        case .submitted:
            result = .submitted
            state.metrics.submittedBlits &+= 1
            if active.completionArrivedWhileSubmitting {
                state.metrics.gpuCompletedBlits &+= 1
                completedImmediately = true
                shouldRelease = true
                state.active = nil
                promotePendingLocked()
            } else {
                active.phase = .gpuInFlight
                state.active = active
            }
        case .drawableUnavailable:
            result = .drawableUnavailable
            state.metrics.drawableUnavailableEvents &+= 1
            state.active = nil
            if state.stopped {
                shouldRelease = true
            } else if let pending = state.pending {
                state.pending = nil
                state.active = Active(work: pending, phase: .queued)
                state.metrics.coalescedFrames &+= 1
                coalescedByNewerFrame = true
                shouldRelease = true
            } else {
                state.pending = active.work.withoutContinuation
            }
        case .invalidSurface:
            result = .invalidSurface
            state.metrics.rejectedFrames &+= 1
            shouldRelease = true
            state.active = nil
            promotePendingLocked()
        case .metalUnavailable:
            result = .metalUnavailable
            state.metrics.rejectedFrames &+= 1
            state.metrics.metalUnavailableFrames &+= 1
            shouldRelease = true
            state.active = nil
            promotePendingLocked()
        }
        lock.unlock()

        guard let work, let result else { return }
        switch backendResult {
        case .submitted:
            metricEventHandler?(.submittedBlit)
        case .drawableUnavailable:
            metricEventHandler?(.drawableUnavailable)
        case .invalidSurface:
            metricEventHandler?(.rejectedFrame)
        case .metalUnavailable:
            metricEventHandler?(.rejectedFrame)
            metricEventHandler?(.metalUnavailable)
        }
        if coalescedByNewerFrame {
            metricEventHandler?(.coalescedFrame)
        }
        record(work.frame, result: result)
        work.continuation?.resume(returning: result)
        if completedImmediately {
            metricEventHandler?(.gpuCompletedBlit)
        }
        if shouldRelease {
            release(work.frame)
        }
    }

    private func submissionCompleted(workID: UInt64) {
        var frameToRelease: TerminalRenderFrame?
        var emitCompletionMetric = false

        lock.lock()
        guard var active = state.active, active.work.id == workID else {
            lock.unlock()
            return
        }
        switch active.phase {
        case .queued:
            lock.unlock()
            return
        case .submitting:
            active.completionArrivedWhileSubmitting = true
            state.active = active
        case .gpuInFlight:
            frameToRelease = active.work.frame
            state.active = nil
            state.metrics.gpuCompletedBlits &+= 1
            emitCompletionMetric = true
            promotePendingLocked()
        }
        lock.unlock()

        if emitCompletionMetric {
            metricEventHandler?(.gpuCompletedBlit)
        }
        if let frameToRelease {
            release(frameToRelease)
        }
    }

    private func submissionPresented(
        workID _: UInt64,
        metadata: TerminalRenderFrameMetadata,
        epoch: UInt64,
        layer: TerminalRenderMetalLayerHandle
    ) {
        lock.lock()
        let matchesCurrentLayer = !state.stopped
            && epoch == state.currentEpoch
            && layer === state.currentLayer
        let advancesSequence = state.highestPresentedFrameSequence.map {
            metadata.frameSequence > $0
        } ?? true
        let shouldPresent = matchesCurrentLayer && advancesSequence
        if shouldPresent {
            state.highestPresentedFrameSequence = metadata.frameSequence
        }
        lock.unlock()
        if shouldPresent {
            presentedHandler?(metadata)
        }
    }

    private func promotePendingLocked() {
        guard !state.stopped,
              state.active == nil,
              let pending = state.pending else {
            return
        }
        state.pending = nil
        state.active = Active(work: pending, phase: .queued)
        scheduleDrainLocked()
    }

    private func release(_ frame: TerminalRenderFrame) {
        lock.lock()
        state.metrics.releasedSurfaces &+= 1
        lock.unlock()
        metricEventHandler?(.releasedSurface)
        releaseHandler(TerminalRenderFrameRelease(frame: frame))

        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        precondition(state.outstandingFrameLeaseCount > 0)
        state.outstandingFrameLeaseCount -= 1
        if state.stopped, state.outstandingFrameLeaseCount == 0 {
            waiters = state.quiescenceWaiters
            state.quiescenceWaiters.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    private func record(
        _ frame: TerminalRenderFrame,
        result: TerminalRenderCompositorEnqueueResult
    ) {
        dispositionHandler?(frame, result)
    }
}
