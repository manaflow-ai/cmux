import CmuxTerminal
import Foundation
import GhosttyKit
import os

/// Coalesces runtime pointer callbacks before they cross onto the main actor.
///
/// Ghostty can report hyperlink state on every cursor-position refresh. The
/// ingress keeps the first and latest shape per runtime, the latest link state,
/// and lifecycle transitions independently. At most one main-queue drain is
/// pending for a view. The active runtime is registered before native surface
/// creation so stale callback contexts are rejected before they can evict data.
/// SAFETY: The weak AppKit view is touched only on the main actor; all
/// callback-thread state is isolated behind ``pendingState``.
final class GhosttyPointerStyleIngress: @unchecked Sendable {
    struct Request {
        enum Event {
            case runtimeReset
            case runtimeEnded
            case shape(ghostty_action_mouse_shape_e)
            case linkHover(Bool)

            @MainActor
            func terminalEvent(runtimeLifetimeId: UUID) -> TerminalPointerStyleEvent {
                switch self {
                case .runtimeReset:
                    return .runtimeReset(runtimeLifetimeId)
                case .runtimeEnded:
                    return .runtimeEnded(runtimeLifetimeId)
                case .shape(let shape):
                    return .ghosttyShape(
                        shape,
                        runtimeLifetimeId: runtimeLifetimeId
                    )
                case .linkHover(let active):
                    return .ghosttyLinkHoverChanged(
                        active,
                        runtimeLifetimeId: runtimeLifetimeId
                    )
                }
            }
        }

        let event: Event
        let surfaceId: UUID
        let runtimeLifetimeId: UUID
    }

    private struct RuntimePending {
        var firstShape: Request?
        var latestShape: Request?
        var latestLinkHover: Request?
        var latestRuntimeReset: Request?
        var latestRuntimeEnded: Request?
    }

    private struct PendingState {
        var activeRuntimeLifetimeId: UUID?
        var retiredRuntimeLifetimeIds: Set<UUID> = []
        var byRuntime: [UUID: RuntimePending] = [:]
        var drainScheduled = false
    }

    private weak var surfaceView: GhosttyNSView?

    /// SAFETY: This lock protects only a bounded callback-to-main latest-value
    /// handoff. No AppKit/domain state is accessed and no await occurs under it.
    private let pendingState = OSAllocatedUnfairLock(
        initialState: PendingState()
    )

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
    }

    /// Starts a new native runtime and drops pending callbacks from older ones.
    func activate(runtimeLifetimeId: UUID) {
        pendingState.withLock { state in
            state.activeRuntimeLifetimeId = runtimeLifetimeId
            state.retiredRuntimeLifetimeIds.remove(runtimeLifetimeId)
            state.byRuntime.removeAll(keepingCapacity: true)
        }
    }

    /// Retires pending callbacks for a runtime that has been torn down.
    func retire(runtimeLifetimeId: UUID?) {
        pendingState.withLock { state in
            guard let runtimeLifetimeId = runtimeLifetimeId ??
                    state.activeRuntimeLifetimeId else {
                state.byRuntime.removeAll(keepingCapacity: true)
                return
            }
            if state.activeRuntimeLifetimeId == runtimeLifetimeId {
                state.activeRuntimeLifetimeId = nil
            }
            state.retiredRuntimeLifetimeIds.insert(runtimeLifetimeId)
            if state.retiredRuntimeLifetimeIds.count > 8,
               let oldest = state.retiredRuntimeLifetimeIds.first {
                state.retiredRuntimeLifetimeIds.remove(oldest)
            }
            state.byRuntime.removeValue(forKey: runtimeLifetimeId)
        }
    }

    /// Submits one callback and schedules at most one pending main-actor drain.
    @discardableResult
    func submit(_ request: Request) -> Bool {
        let shouldSchedule = pendingState.withLock { state in
            guard state.activeRuntimeLifetimeId == request.runtimeLifetimeId,
                  !state.retiredRuntimeLifetimeIds.contains(
                      request.runtimeLifetimeId
                  ) else {
                return false
            }
            var runtime = state.byRuntime[request.runtimeLifetimeId] ??
                RuntimePending()
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
            }
            state.byRuntime[request.runtimeLifetimeId] = runtime

            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }

        guard shouldSchedule else { return true }
        DispatchQueue.main.async { [weak self] in
            self?.drain()
        }
        return true
    }

    @MainActor
    private func drain() {
        let pending = pendingState.withLock { state in
            let pending = state.byRuntime
            state.byRuntime.removeAll(keepingCapacity: true)
            state.drainScheduled = false
            return pending
        }

        guard let surfaceView else { return }
        for runtime in pending.values {
            let requests = [
                runtime.latestRuntimeReset,
                runtime.latestRuntimeEnded,
                runtime.firstShape,
                runtime.latestShape,
                runtime.latestLinkHover
            ].compactMap { $0 }
            for request in requests {
                guard let terminalSurface = surfaceView.terminalSurface,
                      terminalSurface.id == request.surfaceId,
                      terminalSurface.isActiveRuntimeLifetime(
                          request.runtimeLifetimeId
                      ) else {
                    continue
                }
                surfaceView.applyTerminalPointerStyle(
                    request.event.terminalEvent(
                        runtimeLifetimeId: request.runtimeLifetimeId
                    )
                )
            }
        }
    }
}
