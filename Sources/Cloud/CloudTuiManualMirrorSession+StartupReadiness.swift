import CmuxTerminal
import Foundation

/// First-frame readiness for one manual Cloud mirror attachment.
@MainActor
extension CloudTuiManualMirrorSession {
    func beginStartupReadiness(on surface: TerminalSurface) {
        endStartupReadiness()
        startupReadiness.begin(baselineFrame: surface.hostedView.surfaceView.renderedFrameSequence)
        releaseStartupFrameDemand = surface.hostedView.surfaceView.retainLocalRenderedFrameNotifications()
        startupFrameObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: surface.hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStartupFrame() }
        }
        armStartupDeadline()
    }

    func resetStartupReadiness() {
        startupReplayTask?.cancel()
        startupReplayTask = nil
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        startupReadiness.begin(baselineFrame: surface?.hostedView.surfaceView.renderedFrameSequence ?? 0)
        if let surface, startupFrameObserver == nil {
            beginStartupReadiness(on: surface)
        }
    }

    func updateStartupAttachment() {
        armStartupDeadline()
        recordStartupStage("attached")
        _ = startupReadiness.markAttached()
        publishStartupReadinessIfNeeded()
        refreshSurfaceAfterStartupReplayIfNeeded()
    }

    func updateStartupReplay() {
        guard !startupReadiness.replayApplied, startupReplayTask == nil, let surface else { return }
        recordStartupStage("replay-received")
        startupReplayTask = Task { @MainActor [weak self, weak surface] in
            guard let self, let surface else { return }
            defer { if !Task.isCancelled { self.startupReplayTask = nil } }
            guard await surface.waitForRemoteOutput(), !Task.isCancelled,
                  self.surface === surface else { return }
            self.startupReadiness.beginVisiblePresentation(
                baselineFrame: surface.hostedView.surfaceView.renderedFrameSequence
            )
            self.startupReadiness.markReplayApplied()
            self.recordStartupStage("replay-parsed")
            self.refreshSurfaceAfterStartupReplayIfNeeded()
        }
    }

    func updateStartupVisibility(_ visible: Bool) {
        if visible {
            startupReadiness.beginVisiblePresentation(
                baselineFrame: surface?.hostedView.surfaceView.renderedFrameSequence ?? startupReadiness.baselineFrame
            )
            armStartupDeadline()
            refreshSurfaceAfterStartupReplayIfNeeded()
        } else {
            startupDeadlineTask?.cancel()
            startupDeadlineTask = nil
        }
    }

    func updateStartupFrame() {
        guard let surface else { return }
        if startupReadiness.markFramePresented(
            sequence: surface.hostedView.surfaceView.renderedFrameSequence,
            rendererPresented: surface.isRendererPresented,
            effectivelyVisible: surface.isRendererEffectivelyVisible
        ) {
            startupDeadlineTask?.cancel()
            startupDeadlineTask = nil
            publishStartupReadinessIfNeeded()
        }
    }

    func endStartupReadiness() {
        startupReplayTask?.cancel()
        startupReplayTask = nil
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        if let startupFrameObserver {
            NotificationCenter.default.removeObserver(startupFrameObserver)
            self.startupFrameObserver = nil
        }
        releaseStartupFrameDemand?()
        releaseStartupFrameDemand = nil
    }

    private func publishStartupReadinessIfNeeded() {
        guard startupReadiness.isReady else { return }
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        recordStartupStage("usable-frame")
        surface?.hostedView.synchronizeCloudTerminalReconnectOverlay()
        surface?.owningWorkspace()?.postRemoteConnectionPresentationDidChange()
    }

    private func refreshSurfaceAfterStartupReplayIfNeeded() {
        guard startupReadiness.replayApplied,
              phase == .attached,
              let surface,
              surface.isNativeViewInRealWindow,
              surface.isRendererEffectivelyVisible else { return }
        surface.hostedView.refreshSurfaceNow(reason: "cloud.manualMirror.replay")
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
