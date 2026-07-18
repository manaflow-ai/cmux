import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only renderer worker transitions")
struct BackendOnlyRendererWorkerTransitionTests {
    @Test("same-epoch ready is normal readiness, not a restart")
    func sameEpochReadyDoesNotRestart() {
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 7,
            rendererEpoch: 7,
            state: .ready
        ) == .ignore)
    }

    @Test("replacement and unavailable workers restart the presentation")
    func replacementAndUnavailableWorkersRestart() {
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 7,
            rendererEpoch: 8,
            state: .starting
        ) == .restart)
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 7,
            rendererEpoch: 7,
            state: .backoff
        ) == .restart)
        #expect(BackendOnlyRendererWorkerTransition.action(
            currentRendererEpoch: 7,
            priorRendererEpoch: 6,
            rendererEpoch: 7,
            state: .ready
        ) == .ignore)
    }

    @Test("authenticated replacement requires a fresh write-once receiver")
    func replacementWorkerRequiresReceiverRotation() {
        let daemonInstanceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let currentToken = BackendRendererProcessInstanceToken(
            startTimeSeconds: 10,
            startTimeMicroseconds: 20
        )
        let current = BackendOnlyRendererWorkerIdentity(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 7,
            processID: 41,
            effectiveUserID: 501,
            processInstanceToken: currentToken
        )

        #expect(!BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: current,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 7,
            state: .ready,
            processID: 41,
            effectiveUserID: 501,
            processInstanceToken: currentToken
        ))
        #expect(BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: current,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 8,
            state: .ready,
            processID: 42,
            effectiveUserID: 501,
            processInstanceToken: BackendRendererProcessInstanceToken(
                startTimeSeconds: 11,
                startTimeMicroseconds: 21
            )
        ))
        #expect(BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: current,
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: 7,
            state: .backoff,
            processID: nil,
            effectiveUserID: nil,
            processInstanceToken: nil
        ))
    }
}
