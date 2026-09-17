import CmuxTerminal
import Foundation

/// Startup readiness driven by parser completion and native presentation receipts.
@MainActor
extension CloudTuiManualMirrorSession {
    func beginStartupReadiness() {
        endStartupReadiness()
        startupReadiness.begin(baselineFrame: 0)
        armStartupDeadline()
    }

    func resetStartupReadiness() {
        endStartupReadiness()
        startupReadiness.begin(baselineFrame: 0)
    }

    func updateStartupAttachment() {
        armStartupDeadline()
        recordStartupStage("attached")
        startupReadiness.markAttached()
        requestStartupPresentationIfNeeded()
    }

    func updateStartupReplay() {
        if startupReadiness.replayApplied { requestStartupPresentationIfNeeded(); return }
        guard startupReplayTask == nil, let surface else { return }
        recordStartupStage("replay-received")
        startupReplayTask = Task { @MainActor [weak self, weak surface] in
            guard let self, let surface else { return }
            defer { if !Task.isCancelled { self.startupReplayTask = nil } }
            guard await surface.waitForRemoteOutput(), !Task.isCancelled,
                  self.surface === surface else { return }
            self.startupReadiness.markReplayApplied()
            self.recordStartupStage("replay-parsed")
            self.requestStartupPresentationIfNeeded()
        }
    }

    func updateStartupVisibility(_ visible: Bool) {
        startupPresentationTask?.cancel()
        startupPresentationTask = nil
        if visible {
            startupReadiness.beginVisiblePresentation(
                baselineFrame: startupReadiness.presentedFrame ?? startupReadiness.baselineFrame
            )
            armStartupDeadline()
            requestStartupPresentationIfNeeded()
        } else {
            startupDeadlineTask?.cancel()
            startupDeadlineTask = nil
        }
    }

    func endStartupReadiness() {
        startupReplayTask?.cancel()
        startupReplayTask = nil
        startupPresentationTask?.cancel()
        startupPresentationTask = nil
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
    }

    private func requestStartupPresentationIfNeeded() {
        guard startupPresentationTask == nil, !startupReadiness.isReady,
              startupReadiness.replayApplied, phase == .attached,
              let surface, surface.isNativeViewInRealWindow,
              surface.isRendererEffectivelyVisible else { return }
        startupPresentationTask = Task { @MainActor [weak self, weak surface] in
            guard let self, let surface else { return }
            defer { if !Task.isCancelled { self.startupPresentationTask = nil } }
            guard let token = await surface.waitForPresentedFrame(), !Task.isCancelled,
                  self.surface === surface,
                  self.startupReadiness.markFramePresented(
                    sequence: token, rendererPresented: surface.isRendererPresented,
                    effectivelyVisible: surface.isRendererEffectivelyVisible
                  ) else { return }
            self.startupDeadlineTask?.cancel()
            self.startupDeadlineTask = nil
            self.recordStartupStage("usable-frame")
            self.updatePresentationEpisode()
            surface.hostedView.synchronizeCloudTerminalReconnectOverlay()
            surface.owningWorkspace()?.postRemoteConnectionPresentationDidChange()
        }
    }

    func recordStartupStage(_ stage: String) {
        guard startupStages.insert(stage).inserted else { return }
        let elapsed = startupStartedAt.duration(to: .now).components
        log.startupStage(
            machineID: machineID, terminalID: terminalID, stage: stage,
            elapsedMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        )
    }

    private func armStartupDeadline() {
        guard startupDeadlineTask == nil,
              !startupReadiness.isReady,
              surface?.isRendererEffectivelyVisible == true else { return }
        let clock = self.clock
        let deadline = self.deadlines.startup
        startupDeadlineTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(for: deadline) } catch { return }
            guard let self,
                  !self.startupReadiness.isReady,
                  self.phase != .stopped,
                  self.surface?.isRendererEffectivelyVisible == true else { return }
            self.startupDeadlineTask = nil
            self.transitionToDisconnected(reason: .livenessTimedOut)
        }
    }
}
