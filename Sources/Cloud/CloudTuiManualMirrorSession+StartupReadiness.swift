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
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        startupReadiness.begin(baselineFrame: surface?.hostedView.surfaceView.renderedFrameSequence ?? 0)
        if let surface, startupFrameObserver == nil {
            beginStartupReadiness(on: surface)
        } else {
            armStartupDeadline()
        }
    }

    func updateStartupAttachment() {
        _ = startupReadiness.markAttached()
        publishStartupReadinessIfNeeded()
        refreshSurfaceAfterStartupReplayIfNeeded()
    }

    func updateStartupReplay() {
        _ = startupReadiness.markReplayApplied()
        publishStartupReadinessIfNeeded()
        refreshSurfaceAfterStartupReplayIfNeeded()
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
