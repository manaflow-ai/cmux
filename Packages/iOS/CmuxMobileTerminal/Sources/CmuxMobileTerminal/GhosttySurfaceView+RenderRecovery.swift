#if canImport(UIKit)
import CmuxMobileDiagnostics
import GhosttyKit
import QuartzCore
import UIKit

@MainActor
extension GhosttySurfaceView {
    @discardableResult
    func checkSurfaceOperationDeadlines(now: CFTimeInterval) -> Bool {
        if let pending = pendingOutputApply,
           now - pending.startedAt >= effectiveOutputApplyTimeout {
            pendingOutputApply = nil
            let elapsedMs = Int((now - pending.startedAt) * 1000)
            MobileDebugLog.anchormux(
                "output.apply.TIMEOUT bytes=\(pending.byteCount ?? 0) elapsedMs=\(elapsedMs)"
            )
            let recovered = recoverRenderPipeline(
                reason: "output_timeout",
                stalledMs: elapsedMs,
                replay: .callerWillRequestReplay
            )
            pending.continuation.resume(returning: false)
            return recovered
        }

        if let pending = pendingGeometryApply,
           now - pending.startedAt >= Self.outputApplyTimeout {
            pendingGeometryApply = nil
            let elapsedMs = Int((now - pending.startedAt) * 1000)
            MobileDebugLog.anchormux("geometry.apply.TIMEOUT elapsedMs=\(elapsedMs)")
            let recovered = recoverRenderPipeline(
                reason: "geometry_timeout",
                stalledMs: elapsedMs,
                replay: .callerWillRequestReplay
            )
            pending.continuation.resume(returning: false)
            return recovered
        }

        if let pending = pendingVisibleSnapshot,
           now - pending.startedAt >= Self.visibleSnapshotTimeout {
            pendingVisibleSnapshot = nil
            pending.continuation.resume(returning: nil)
        }

        if let pending = pendingCopyableTextRead,
           now - pending.startedAt >= Self.copyableTextTimeout {
            pendingCopyableTextRead = nil
            pending.cancel()
            pending.continuation.resume(returning: nil)
        }
        return false
    }

    var effectiveOutputApplyTimeout: CFTimeInterval {
        guard consecutiveOutputTimeoutRecoveries > 0 else { return Self.outputApplyTimeout }
        let multiplier = min(8, 1 << min(consecutiveOutputTimeoutRecoveries, 3))
        return min(Self.outputApplyTimeout * CFTimeInterval(multiplier), Self.maxOutputApplyTimeout)
    }

    func logRecoveryPausedDrop(kind: String, byteCount: Int? = nil) {
        let now = CACurrentMediaTime()
        guard now - lastRecoveryPausedDropLogTime >= 1 else { return }
        lastRecoveryPausedDropLogTime = now
        MobileDebugLog.anchormux(
            "render.recover.paused_drop kind=\(kind) bytes=\(byteCount ?? 0) pendingFrees=\(pendingSurfaceFreeCount)"
        )
    }

    @discardableResult
    func pauseRenderPipelineRecovery(
        reason: String,
        stalledMs: Int
    ) -> Bool {
        let now = CACurrentMediaTime()
        MobileDebugLog.anchormux(
            "render.recover.paused reason=\(reason) stalledMs=\(stalledMs) pendingFrees=\(pendingSurfaceFreeCount)"
        )
        renderPipelineRecoveryPaused = true
        renderPipelineRecoveryPausedAt = now
        ensureRenderPipelineRecoveryResumeTimer()
        stopDisplayLink()
        _ = completePendingSurfaceOperations(returning: false)
        renderInFlight = false
        renderInFlightSince = nil
        needsAnotherRender = false
        needsDraw = false
        return true
    }

    func resumePausedRenderPipelineRecoveryIfPossible() {
        guard renderPipelineRecoveryPaused,
              !isDismantled,
              surface != nil else { return }
        let now = CACurrentMediaTime()
        let pausedElapsed = renderPipelineRecoveryPausedAt.map { now - $0 } ?? 0
        guard pendingSurfaceFreeCount < Self.maxPendingSurfaceFrees
                || pausedElapsed >= Self.renderPipelineRecoveryResumeInterval else {
            return
        }
        MobileDebugLog.anchormux(
            "render.recover.resuming pendingFrees=\(pendingSurfaceFreeCount)"
        )
        renderPipelineRecoveryPaused = false
        renderPipelineRecoveryPausedAt = nil
        cancelRenderPipelineRecoveryResumeTimer()
        let recovered = recoverRenderPipeline(
            reason: "free_drained",
            stalledMs: 0,
            replay: .callerWillRequestReplay
        )
        if recovered {
            delegate?.ghosttySurfaceViewDidResetRenderPipeline(self)
        }
    }

    func ensureRenderPipelineRecoveryResumeTimer() {
        guard renderPipelineRecoveryResumeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.renderPipelineRecoveryResumeInterval,
            repeating: Self.renderPipelineRecoveryResumeInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.resumePausedRenderPipelineRecoveryIfPossible()
            }
        }
        renderPipelineRecoveryResumeTimer = timer
        timer.resume()
    }

    func cancelRenderPipelineRecoveryResumeTimer() {
        renderPipelineRecoveryResumeTimer?.cancel()
        renderPipelineRecoveryResumeTimer = nil
    }

    @discardableResult
    func recoverRenderPipeline(
        reason: String,
        stalledMs: Int,
        replay: RenderPipelineRecoveryReplay
    ) -> Bool {
        guard !isDismantled,
              surface != nil else {
            return false
        }
        guard !renderPipelineRecoveryPaused else {
            return pauseRenderPipelineRecovery(reason: reason, stalledMs: stalledMs)
        }
        guard pendingSurfaceFreeCount < Self.maxPendingSurfaceFrees else {
            return pauseRenderPipelineRecovery(reason: reason, stalledMs: stalledMs)
        }
        if reason == "output_timeout" {
            consecutiveOutputTimeoutRecoveries += 1
        } else {
            consecutiveOutputTimeoutRecoveries = 0
        }
        MobileDebugLog.anchormux(
            "render.recover reason=\(reason) stalledMs=\(stalledMs) generation=\(surfaceGeneration) pendingFrees=\(pendingSurfaceFreeCount)"
        )
        let completedFailedOperation = completePendingSurfaceOperations(returning: false)

        stopDisplayLink()
        let oldSurface = surface
        let oldBridge = bridge
        let oldQueue = outputQueue
        oldBridge.detach()
        if let oldSurface {
            GhosttySurfaceView.unregister(surface: oldSurface)
            pendingSurfaceFreeCount += 1
            enqueueSurfaceFree(oldSurface, bridge: oldBridge, on: oldQueue) { [weak self] in
                guard let self else { return }
                self.pendingSurfaceFreeCount = max(0, self.pendingSurfaceFreeCount - 1)
                MobileDebugLog.anchormux(
                    "render.recover.free_drained pendingFrees=\(self.pendingSurfaceFreeCount)"
                )
                self.resumePausedRenderPipelineRecoveryIfPossible()
            }
        }

        surface = nil
        renderInFlight = false
        renderInFlightSince = nil
        needsAnotherRender = false
        needsDraw = true
        cellPixelSize = .zero
        lastRenderRect = .zero
        lastRenderLayoutViewportHeight = nil
        lastRenderHasSourceLayoutViewport = false
        lastAppliedContentScale = 0

        surfaceGeneration &+= 1
        outputQueueGeneration &+= 1
        outputQueue = GhosttySurfaceWorkQueue(generation: outputQueueGeneration)
        scrollToBottomInFlight = false
        bridge = GhosttySurfaceBridge()
        bridge.attach(to: self)

        initializeSurface()
        if replay == .delegateWhenNoCaller && !completedFailedOperation {
            delegate?.ghosttySurfaceViewDidResetRenderPipeline(self)
        }
        return true
    }
}
#endif
