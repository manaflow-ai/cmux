import CmuxTerminal
import Foundation
import GhosttyKit

/// Coalesces runtime pointer callbacks before they cross onto the main actor.
///
/// Ghostty can report hyperlink state on every cursor-position refresh. A
/// latest-value stream keeps one bounded event per terminal view while still
/// revalidating the surface and runtime lifetime at delivery time.
final class GhosttyPointerStyleIngress: Sendable {
    struct Request: Sendable {
        /// Immutable callback data copied before the native callback returns.
        ///
        /// SAFETY: The only non-Swift value is Ghostty's C enum, which is an
        /// immutable integer-shaped ABI value and is never mutated or retained
        /// across the actor hop.
        enum Event: @unchecked Sendable {
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

    private let continuation: AsyncStream<Request>.Continuation
    private let consumerTask: Task<Void, Never>

    init(surfaceView: GhosttyNSView) {
        let (stream, continuation) = AsyncStream<Request>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        consumerTask = Task { @MainActor [weak surfaceView] in
            for await request in stream {
                guard !Task.isCancelled,
                      let surfaceView,
                      let terminalSurface = surfaceView.terminalSurface,
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

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    /// Submits one callback; the stream retains only the newest pending event.
    @discardableResult
    func submit(_ request: Request) -> Bool {
        switch continuation.yield(request) {
        case .enqueued, .dropped:
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }
}
