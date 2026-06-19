import Foundation
#if DEBUG
internal import CMUXDebugLog
#endif

extension TerminalSurface {
    // Background priming may still be restore-paced; socket/API input is an
    // explicit runtime demand and must not sit behind unrelated restored panes.
    /// Requests a cold runtime start for background priming.
    @MainActor
    public func requestBackgroundSurfaceStartIfNeeded() {
        requestSurfaceStartIfNeeded(source: .normal, reason: "background-input")
    }

    /// Requests a cold runtime start for visible user or socket input.
    @MainActor
    public func requestInputDemandSurfaceStartIfNeeded() {
        requestSurfaceStartIfNeeded(source: .inputDemand, reason: "input-demand")
    }

    @MainActor
    private func requestSurfaceStartIfNeeded(
        source: RuntimeSurfaceCreationSource,
        reason: String
    ) {
        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }

        backgroundSurfaceStartSource = backgroundSurfaceStartSource.promoted(with: source)
        guard !backgroundSurfaceStartQueued else { return }
        backgroundSurfaceStartQueued = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let source = self.backgroundSurfaceStartSource
            self.backgroundSurfaceStartQueued = false
            self.backgroundSurfaceStartSource = .normal
            guard self.allowsRuntimeSurfaceCreation() else { return }
            guard self.surface == nil else { return }
        #if DEBUG
            let startedAt = ProcessInfo.processInfo.systemUptime
        #endif
            if let view = self.attachedView, view.window != nil {
                self.createSurface(for: view, source: source)
            } else {
                self.scheduleHeadlessRuntimeStartIfNeeded(reason: reason, source: source)
            }
        #if DEBUG
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            let view = self.attachedView ?? self.surfaceView
            logDebugEvent(
                "surface.background_start surface=\(self.id.uuidString.prefix(8)) " +
                "inWindow=\(view.window != nil ? 1 : 0) ready=\(self.surface != nil ? 1 : 0) " +
                "source=\(source) ms=\(String(format: "%.2f", elapsedMs))"
            )
        #endif
        }
    }
}
