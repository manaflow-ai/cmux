import CmuxTerminal
import CmuxFoundation
import Foundation

/// Coalesces runtime pointer callbacks before they cross onto the main actor.
///
/// Ghostty can report hyperlink state on every cursor-position refresh. The
/// ingress actor keeps the first and latest shape per runtime, the latest link
/// state, and lifecycle transitions independently. Lifecycle transitions use
/// their own bounded channel so pointer traffic cannot evict a reset/end. At
/// most one main-actor drain is pending for a view; stale runtime IDs are
/// rejected before enqueue.
actor GhosttyPointerStyleIngress {
    private weak var surfaceView: GhosttyNSView?
    nonisolated private let focusGeneration = AtomicUInt64Generation()
    nonisolated private let focusState = AtomicBooleanGate(false)
    nonisolated private let runtimeGeneration = AtomicUInt64Generation()
    nonisolated private let submissionSequence = AtomicUInt64Generation()
    nonisolated private let lifecycleSubmissionSequence = AtomicUInt64Generation()
    private var state = GhosttyPointerStyleIngressPendingState(
        activeRuntimeLifetimeId: nil
    )
    private var lastProcessedLifecycleSequence: UInt64 = 0
    private var lifecycleWaiters: [
        (through: UInt64, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private let continuation: AsyncStream<GhosttyPointerStyleIngressRequest>.Continuation
    private let lifecycleContinuation: AsyncStream<GhosttyPointerStyleIngressRequest>.Continuation
    private var consumerTask: Task<Void, Never>?
    private var lifecycleConsumerTask: Task<Void, Never>?

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        let (stream, continuation) = AsyncStream<GhosttyPointerStyleIngressRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let (lifecycleStream, lifecycleContinuation) =
            AsyncStream<GhosttyPointerStyleIngressRequest>.makeStream(
                bufferingPolicy: .bufferingNewest(2)
            )
        self.continuation = continuation
        self.lifecycleContinuation = lifecycleContinuation
        consumerTask = Task { [weak self] in
            for await request in stream {
                guard let self else { return }
                await self.receive(request)
            }
        }
        lifecycleConsumerTask = Task { [weak self] in
            for await request in lifecycleStream {
                guard let self else { return }
                await self.receive(request)
            }
        }
    }

    deinit {
        continuation.finish()
        lifecycleContinuation.finish()
        consumerTask?.cancel()
        lifecycleConsumerTask?.cancel()
    }

    /// Registers a native runtime before Ghostty can emit its first action.
    @discardableResult
    nonisolated func activate(runtimeLifetimeId: UUID, surfaceId: UUID) -> UInt64 {
        let generation = runtimeGeneration.advanceRelease()
        Task {
            await self.activateIsolated(
                runtimeLifetimeId: runtimeLifetimeId,
                generation: generation
            )
        }
        return generation
    }

    /// Retires a runtime; `nil` unconditionally retires the currently active one.
    nonisolated func retire(runtimeLifetimeId: UUID?, surfaceId: UUID) {
        // Retirement only tombstones the lifetime. The next activation owns
        // generation advancement; an old delayed teardown must not invalidate
        // callbacks from the replacement runtime.
        let generation = runtimeGeneration.loadAcquire()
        Task {
            await self.retireIsolated(
                runtimeLifetimeId: runtimeLifetimeId,
                generation: generation
            )
        }
    }

    /// Advances the focus epoch so queued transient hover events cannot be
    /// replayed after a focus transition.
    nonisolated func focusChanged(_ focused: Bool) {
        let expected = focused ? false : true
        guard focusState.compareExchange(expected: expected, desired: focused) else {
            return
        }
        _ = focusGeneration.advanceRelaxed()
    }

    /// Captures one callback without waiting for the main actor.
    nonisolated func submit(_ request: GhosttyPointerStyleIngressRequest) {
        guard request.runtimeGeneration == runtimeGeneration.loadAcquire() else {
            return
        }
        var request = request
        request.focusGeneration = focusGeneration.loadRelaxed()
        request.sequence = submissionSequence.advanceRelease()
        switch request.event {
        case .runtimeReset, .runtimeEnded:
            // Lifecycle transitions use a separate bounded channel so a
            // burst of shape/link callbacks cannot evict a required reset.
            request.lifecycleSequence = lifecycleSubmissionSequence.advanceRelease()
            lifecycleContinuation.yield(request)
        case .activate, .retire(_), .shape, .linkHover:
            continuation.yield(request)
        }
    }

    private func activateIsolated(
        runtimeLifetimeId: UUID,
        generation: UInt64
    ) {
        guard generation >= state.activeRuntimeGeneration else { return }
        if state.activeRuntimeLifetimeId != runtimeLifetimeId ||
           state.activeRuntimeGeneration != generation {
            state.activeRuntimeLifetimeId = runtimeLifetimeId
            state.activeRuntimeGeneration = generation
            state.byRuntime.removeAll(keepingCapacity: true)
        }
        state.retiredRuntimeLifetimeIds.remove(runtimeLifetimeId)
    }

    private func retireIsolated(
        runtimeLifetimeId: UUID?,
        generation: UInt64
    ) {
        guard let runtimeLifetimeId else {
            return
        }
        if state.activeRuntimeLifetimeId != runtimeLifetimeId {
            rememberRetiredRuntime(runtimeLifetimeId)
            return
        }
        guard generation >= state.activeRuntimeGeneration,
              state.activeRuntimeGeneration == generation else {
            return
        }
        state.activeRuntimeLifetimeId = nil
        state.activeRuntimeGeneration = generation
        rememberRetiredRuntime(runtimeLifetimeId)
    }

    private func rememberRetiredRuntime(_ runtimeLifetimeId: UUID) {
        state.retiredRuntimeLifetimeIds.insert(runtimeLifetimeId)
        if state.retiredRuntimeLifetimeIds.count > 8,
           let oldest = state.retiredRuntimeLifetimeIds.first {
            state.retiredRuntimeLifetimeIds.remove(oldest)
        }
        state.byRuntime.removeValue(forKey: runtimeLifetimeId)
    }

    private func receive(_ incoming: GhosttyPointerStyleIngressRequest) {
        let request = incoming
        let lifecycleSequence = request.lifecycleSequence
        defer {
            if lifecycleSequence > 0 {
                markLifecycleProcessed(lifecycleSequence)
            }
        }

        switch request.event {
        case .activate:
            state.activeRuntimeLifetimeId = request.runtimeLifetimeId
            state.retiredRuntimeLifetimeIds.remove(request.runtimeLifetimeId)
            state.byRuntime.removeAll(keepingCapacity: true)
            return

        case .retire(let requestedID):
            let retiredID: UUID
            if let requestedID {
                guard state.activeRuntimeLifetimeId == requestedID else {
                    rememberRetiredRuntime(requestedID)
                    return
                }
                retiredID = requestedID
            } else {
                guard let activeRuntimeLifetimeId = state.activeRuntimeLifetimeId else {
                    return
                }
                retiredID = activeRuntimeLifetimeId
            }
            state.activeRuntimeLifetimeId = nil
            state.activeRuntimeGeneration = max(
                state.activeRuntimeGeneration,
                request.runtimeGeneration
            )
            rememberRetiredRuntime(retiredID)
            return

        case .runtimeReset, .runtimeEnded, .shape, .linkHover:
            guard !state.retiredRuntimeLifetimeIds.contains(
                request.runtimeLifetimeId
            ) else {
                return
            }
            if request.runtimeGeneration > state.activeRuntimeGeneration {
                state.activeRuntimeLifetimeId = request.runtimeLifetimeId
                state.activeRuntimeGeneration = request.runtimeGeneration
                state.byRuntime.removeAll(keepingCapacity: true)
            }
            guard state.activeRuntimeLifetimeId == request.runtimeLifetimeId,
                  state.activeRuntimeGeneration == request.runtimeGeneration else {
                return
            }
        }

        var runtime = state.byRuntime[request.runtimeLifetimeId] ??
            GhosttyPointerStyleIngressRuntimePending()
        if runtime.latestRuntimeEnded != nil {
            guard case .runtimeEnded = request.event else { return }
        }
        switch request.event {
        case .runtimeReset:
            if (runtime.latestRuntimeReset?.sequence ?? 0) <= request.sequence {
                runtime.latestRuntimeReset = request
            }
            if (runtime.firstShape?.sequence ?? 0) <= request.sequence {
                runtime.firstShape = nil
            }
            if (runtime.latestShape?.sequence ?? 0) <= request.sequence {
                runtime.latestShape = nil
            }
            if (runtime.latestLinkHover?.sequence ?? 0) <= request.sequence {
                runtime.latestLinkHover = nil
            }
        case .runtimeEnded:
            guard (runtime.latestRuntimeEnded?.sequence ?? 0) <= request.sequence else {
                return
            }
            runtime.latestRuntimeEnded = request
            runtime.firstShape = nil
            runtime.latestShape = nil
            runtime.latestLinkHover = nil
        case .shape:
            if (runtime.latestRuntimeReset?.sequence ?? 0) >= request.sequence ||
               (runtime.latestRuntimeEnded?.sequence ?? 0) >= request.sequence {
                return
            }
            if runtime.firstShape == nil {
                runtime.firstShape = request
            }
            runtime.latestShape = request
        case .linkHover:
            if (runtime.latestRuntimeReset?.sequence ?? 0) >= request.sequence ||
               (runtime.latestRuntimeEnded?.sequence ?? 0) >= request.sequence {
                return
            }
            runtime.latestLinkHover = request
        case .activate, .retire(_):
            break
        }
        state.byRuntime[request.runtimeLifetimeId] = runtime
        scheduleDrainIfNeeded()
    }

    private func scheduleDrainIfNeeded() {
        guard !state.drainScheduled else { return }
        state.drainScheduled = true
        let surfaceView = self.surfaceView
        let lifecycleBarrier = lifecycleSubmissionSequence.loadAcquire()
        Task { @MainActor [weak self, weak surfaceView] in
            guard let self else { return }
            let pending = await self.takePending(
                afterLifecycleSequence: lifecycleBarrier
            )
            guard let surfaceView else { return }
            for runtime in pending.values {
                var requests: [GhosttyPointerStyleIngressRequest] = []
                if let reset = runtime.latestRuntimeReset { requests.append(reset) }
                if let ended = runtime.latestRuntimeEnded { requests.append(ended) }
                if let firstShape = runtime.firstShape {
                    requests.append(firstShape)
                    if let latestShape = runtime.latestShape,
                       latestShape.sequence != firstShape.sequence {
                        requests.append(latestShape)
                    }
                }
                if let linkHover = runtime.latestLinkHover { requests.append(linkHover) }
                requests.sort { $0.sequence < $1.sequence }

                for request in requests {
                    if case .linkHover = request.event,
                       request.focusGeneration != focusGeneration.loadRelaxed() {
                        continue
                    }
                    guard let terminalSurface = surfaceView.terminalSurface,
                          terminalSurface.id == request.surfaceId,
                          terminalSurface.isActiveRuntimeLifetime(
                              request.runtimeLifetimeId
                          ),
                          let event = request.event.terminalEvent(
                              runtimeLifetimeId: request.runtimeLifetimeId
                          ) else {
                        continue
                    }
                    let eventFocusGeneration: UInt64?
                    switch request.event {
                    case .shape, .linkHover:
                        eventFocusGeneration = request.focusGeneration
                    case .activate, .retire(_), .runtimeReset, .runtimeEnded:
                        eventFocusGeneration = nil
                    }
                    surfaceView.applyTerminalPointerStyle(
                        event,
                        focusGeneration: eventFocusGeneration
                    )
                }
            }
        }
    }

    private func takePending(
        afterLifecycleSequence lifecycleSequence: UInt64
    ) async -> [
        UUID: GhosttyPointerStyleIngressRuntimePending
    ] {
        await waitForLifecycleThrough(lifecycleSequence)
        let pending = state.byRuntime
        state.byRuntime.removeAll(keepingCapacity: true)
        state.drainScheduled = false
        return pending
    }

    private func waitForLifecycleThrough(_ sequence: UInt64) async {
        guard lastProcessedLifecycleSequence < sequence else { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append((sequence, continuation))
        }
    }

    private func markLifecycleProcessed(_ sequence: UInt64) {
        guard sequence > lastProcessedLifecycleSequence else { return }
        lastProcessedLifecycleSequence = sequence
        var ready: [CheckedContinuation<Void, Never>] = []
        lifecycleWaiters.removeAll { waiter in
            guard waiter.through <= sequence else { return false }
            ready.append(waiter.continuation)
            return true
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}
