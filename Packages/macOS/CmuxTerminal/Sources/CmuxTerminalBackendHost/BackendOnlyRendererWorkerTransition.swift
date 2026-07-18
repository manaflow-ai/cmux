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
        guard rendererEpoch == currentRendererEpoch, state == .ready else {
            return .restart
        }
        return .ignore
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
        guard let currentWorker else { return false }
        guard currentWorker.daemonInstanceID == daemonInstanceID,
              currentWorker.rendererEpoch == rendererEpoch,
              state == .ready,
              let processID,
              let signedProcessID = pid_t(exactly: processID),
              let effectiveUserID,
              let processInstanceToken else {
            return true
        }
        return currentWorker.processID != signedProcessID
            || currentWorker.effectiveUserID != effectiveUserID
            || currentWorker.processInstanceToken != processInstanceToken
    }
}
