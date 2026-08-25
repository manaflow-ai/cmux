import CmuxTerminal
import Foundation
import GhosttyKit
import os

/// Coalesces runtime pointer callbacks before they cross onto the main actor.
///
/// Ghostty can report hyperlink state on every cursor-position refresh. The
/// ingress keeps independent latest values for shape and link state, while
/// lifecycle resets remain ordered ahead of those values. At most one main
/// queue drain is pending for a view.
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

    private struct PendingState {
        var latestShape: Request?
        var latestLinkHover: Request?
        var latestRuntimeReset: Request?
        var latestRuntimeEnded: Request?
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

    /// Submits one callback and schedules at most one pending main-actor drain.
    @discardableResult
    func submit(_ request: Request) -> Bool {
        let shouldSchedule = pendingState.withLock { state in
            switch request.event {
            case .runtimeReset:
                state.latestRuntimeReset = request
            case .runtimeEnded:
                state.latestRuntimeEnded = request
            case .shape:
                state.latestShape = request
            case .linkHover:
                state.latestLinkHover = request
            }

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
        let snapshot = pendingState.withLock { state in
            let snapshot = (
                runtimeReset: state.latestRuntimeReset,
                runtimeEnded: state.latestRuntimeEnded,
                shape: state.latestShape,
                linkHover: state.latestLinkHover
            )
            state.latestRuntimeReset = nil
            state.latestRuntimeEnded = nil
            state.latestShape = nil
            state.latestLinkHover = nil
            state.drainScheduled = false
            return snapshot
        }

        guard let surfaceView else { return }
        for request in [
            snapshot.runtimeReset,
            snapshot.runtimeEnded,
            snapshot.shape,
            snapshot.linkHover
        ].compactMap({ $0 }) {
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
