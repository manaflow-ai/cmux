#if canImport(UIKit)
import UIKit

extension GhosttySurfaceView {
    static let renderFlightTimeout: CFTimeInterval = 3.0
    static let renderQueueTimeout: CFTimeInterval = 10.0
    static let recoveryReplayApplyTimeoutSeconds: Double = 2.0

    func scheduleRecoveryReplayAttempt() {
        recoveryReplayTask?.cancel()
        switch surfaceSession.beginReplayAttempt() {
        case .none:
            return
        case let .request(generation, attempt):
            MobileDebugLog.anchormux("render.replay request generation=\(generation) attempt=\(attempt)")
            recoveryReplayTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                let delivered = await self.delegate?.ghosttySurfaceViewNeedsReplay(self) ?? false
                self.handleRecoveryReplayResult(generation: generation, deliveredOutput: delivered)
            }
        case let .failClosed(generation):
            MobileDebugLog.anchormux("render.replay fail_closed generation=\(generation) reason=max_attempts_before_request")
            syncSnapshotFallback()
        }
    }

    func handleRecoveryReplayResult(generation: UInt64, deliveredOutput: Bool) {
        switch surfaceSession.completeReplayAttempt(
            generation: generation,
            deliveredOutput: deliveredOutput
        ) {
        case .ignored:
            return
        case .delivered:
            recoveryReplayTask = Task { @MainActor [weak self] in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + Self.recoveryReplayApplyTimeoutSeconds
                    ) {
                        continuation.resume()
                    }
                }
                guard let self,
                      !Task.isCancelled,
                      self.surfaceSession.isAwaitingReplayOutput(generation: generation) else {
                    return
                }
                MobileDebugLog.anchormux("render.replay apply_timeout generation=\(generation)")
                self.handleRecoveryReplayResult(generation: generation, deliveredOutput: false)
            }
        case let .retry(retryGeneration):
            MobileDebugLog.anchormux("render.replay retry generation=\(retryGeneration)")
            scheduleRecoveryReplayAttempt()
        case let .failClosed(failedGeneration):
            MobileDebugLog.anchormux("render.replay fail_closed generation=\(failedGeneration) reason=replay_failed")
            recoveryReplayTask?.cancel()
            recoveryReplayTask = nil
            syncSnapshotFallback()
        }
    }
}
#endif
