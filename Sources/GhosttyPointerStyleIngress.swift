import CmuxTerminal
import Foundation

/// Coalesces runtime pointer callbacks before they cross onto the main actor.
///
/// Ghostty can report hyperlink state on every cursor-position refresh. The
/// ingress actor keeps the first and latest shape per runtime, the latest link
/// state, and lifecycle transitions independently. At most one main-actor
/// drain is pending for a view; stale runtime IDs are rejected before enqueue.
actor GhosttyPointerStyleIngress {
    private weak var surfaceView: GhosttyNSView?
    private var state = GhosttyPointerStyleIngressPendingState(
        activeRuntimeLifetimeId: nil
    )
    private let continuation: AsyncStream<GhosttyPointerStyleIngressRequest>.Continuation
    private var consumerTask: Task<Void, Never>?

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        let (stream, continuation) = AsyncStream<GhosttyPointerStyleIngressRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.continuation = continuation
        consumerTask = Task { [weak self] in
            for await request in stream {
                guard let self else { return }
                await self.receive(request)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
    }

    /// Registers a native runtime before Ghostty can emit its first action.
    nonisolated func activate(runtimeLifetimeId: UUID, surfaceId: UUID) {
        submit(.init(
            event: .activate,
            surfaceId: surfaceId,
            runtimeLifetimeId: runtimeLifetimeId
        ))
    }

    /// Retires a runtime; `nil` unconditionally retires the currently active one.
    nonisolated func retire(runtimeLifetimeId: UUID?, surfaceId: UUID) {
        submit(.init(
            event: .retire(runtimeLifetimeId),
            surfaceId: surfaceId,
            runtimeLifetimeId: runtimeLifetimeId ?? UUID()
        ))
    }

    /// Captures one callback without waiting for the main actor.
    nonisolated func submit(_ request: GhosttyPointerStyleIngressRequest) {
        continuation.yield(request)
    }

    private func receive(_ incoming: GhosttyPointerStyleIngressRequest) {
        var request = incoming
        state.nextSequence &+= 1
        request.sequence = state.nextSequence

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
            state.retiredRuntimeLifetimeIds.insert(retiredID)
            if state.retiredRuntimeLifetimeIds.count > 8,
               let oldest = state.retiredRuntimeLifetimeIds.first {
                state.retiredRuntimeLifetimeIds.remove(oldest)
            }
            state.byRuntime.removeValue(forKey: retiredID)
            return

        case .runtimeReset, .runtimeEnded, .shape, .linkHover:
            guard state.activeRuntimeLifetimeId == request.runtimeLifetimeId,
                  !state.retiredRuntimeLifetimeIds.contains(
                      request.runtimeLifetimeId
                  ) else {
                return
            }
        }

        var runtime = state.byRuntime[request.runtimeLifetimeId] ??
            GhosttyPointerStyleIngressRuntimePending()
        switch request.event {
        case .runtimeReset:
            runtime.latestRuntimeReset = request
            runtime.firstShape = nil
            runtime.latestShape = nil
            runtime.latestLinkHover = nil
        case .runtimeEnded:
            runtime.latestRuntimeEnded = request
            runtime.firstShape = nil
            runtime.latestShape = nil
            runtime.latestLinkHover = nil
        case .shape:
            if runtime.firstShape == nil {
                runtime.firstShape = request
            }
            runtime.latestShape = request
        case .linkHover:
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
        Task { @MainActor [weak self, weak surfaceView] in
            guard let self else { return }
            let pending = await self.takePending()
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

                for request in requests {
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
                    surfaceView.applyTerminalPointerStyle(event)
                }
            }
        }
    }

    private func takePending() -> [
        UUID: GhosttyPointerStyleIngressRuntimePending
    ] {
        let pending = state.byRuntime
        state.byRuntime.removeAll(keepingCapacity: true)
        state.drainScheduled = false
        return pending
    }
}
