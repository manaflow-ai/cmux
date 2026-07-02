import Foundation
internal import CmuxMobileDiagnostics

extension MobileShellComposite {
    func prepareTerminalReplayFailureRetry(
        surfaceID: String,
        replayBarrierToken: UUID?
    ) -> UUID? {
        guard let replayBarrierToken,
              hasTerminalOutputSink(surfaceID: surfaceID),
              terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken else {
            return nil
        }
        guard prepareTerminalReplayFailureRetry(surfaceID: surfaceID) else {
            return nil
        }
        return replayBarrierToken
    }

    func prepareNonBarrierTerminalReplayFailureRetry(surfaceID: String) -> Bool {
        guard remoteClient != nil else { return false }
        return prepareTerminalReplayFailureRetry(surfaceID: surfaceID)
    }

    func terminalReplayFailureRetryExhausted(surfaceID: String) -> Bool {
        (terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0) >= Self.maxTerminalReplayFailureRetries
    }

    private func prepareTerminalReplayFailureRetry(surfaceID: String) -> Bool {
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return false }
        let retryCount = terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0
        guard retryCount < Self.maxTerminalReplayFailureRetries else {
            MobileDebugLog.anchormux(
                "CMUX_REPLAY retry_exhausted surface=\(surfaceID) attempts=\(retryCount)"
            )
            return false
        }
        terminalReplayFailureRetryCountsBySurfaceID[surfaceID] = retryCount + 1
        MobileDebugLog.anchormux(
            "CMUX_REPLAY retry_after_failure surface=\(surfaceID) attempt=\(retryCount + 1)"
        )
        return true
    }
}
