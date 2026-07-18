internal import CmuxTerminalBackend
internal import Darwin
internal import Foundation

enum BackendOnlyRendererWorkerTransitionAction: Equatable, Sendable {
    case ignore
    case restart
}

struct BackendOnlyRendererWorkerTransition: Sendable {
    static func action(
        currentRendererEpoch: UInt64?,
        priorRendererEpoch: UInt64,
        rendererEpoch: UInt64?,
        state: BackendRendererWorkerState?
    ) -> BackendOnlyRendererWorkerTransitionAction {
        guard currentRendererEpoch == priorRendererEpoch else { return .ignore }
        return .restart
    }

    static func requiresReceiverRotation(
        currentWorker: BackendOnlyRendererWorkerIdentity?,
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        state: BackendRendererWorkerState,
        processID: UInt32?,
        effectiveUserID: UInt32?,
        processInstanceToken: BackendRendererProcessInstanceToken?
    ) -> Bool {
        false
    }
}
