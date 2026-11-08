import CmuxControlSocket
import CmuxSettings
import Foundation

/// The composition-root wiring of ``SocketControlServerEvents`` for the app:
/// listener breadcrumbs and failures go to Sentry, marker files to the
/// discovery store, and lifecycle hooks back to the controller.
extension TerminalController {
    /// Builds the package server's host-callback seam. `target` is filled in
    /// at the end of `init`; no listener event can fire before `start`.
    nonisolated static func makeSocketServerEvents(
        target: ServerEventTarget,
        markerStore: SocketPathMarkerStore,
        failureCaptureGate: SocketListenerFailureCaptureGate
    ) -> SocketControlServerEvents {
        SocketControlServerEvents(
            breadcrumb: { message, data in
                sentryBreadcrumb(message, category: "socket", data: data)
            },
            failure: { message, stage, errnoCode, data in
                sentryBreadcrumb(message, category: "socket", data: data)
                guard failureCaptureGate.shouldCapture(
                    message: message,
                    stage: stage,
                    path: data["path"] as? String ?? "",
                    errnoCode: errnoCode
                ) else {
                    return
                }
                sentryCaptureError(message, category: "socket", data: data, contextKey: "socket_listener")
            },
            listenerDidStart: { path, _ in
                // @MainActor closure, invoked synchronously inside start().
                failureCaptureGate.listenerDidStart()
                target.controller?.socketListenerDidStart(path: path)
            },
            recordLastSocketPath: { path in
                markerStore.record(path)
            },
            cleanupDiscoveryState: { path in
                target.controller?.cleanupStoppedSocketState(path)
            },
            pathMissingDetected: { path, generation in
                Task { @MainActor in
                    target.controller?.restartSocketListenerIfPathMissing(path: path, generation: generation)
                }
            },
            rearmRequested: { generation, errnoCode, consecutiveFailures, delayMs in
                target.controller?.scheduleListenerRearm(
                    generation: generation,
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures,
                    delayMs: delayMs
                )
            },
            connectionDropped: { socket, _ in
                // Listener-queue callback: the accept buffer was full. Answer
                // the client with `overloaded` instead of a bare close.
                guard let controller = target.controller else {
                    close(socket)
                    return
                }
                controller.rejectSocketClient(socket, reason: .acceptBufferFull)
            }
        )
    }
}
