import AppKit
import CmuxTerminalCore

extension TerminalSurface {
    /// Reopens the presentation gate after AppKit commits a new drawable size.
    ///
    /// A failed tokened frame is bounded within one geometry episode, but a
    /// later size or backing-scale commit is a new host-layer opportunity. The
    /// renderer therefore receives one fresh tokened probe on that signal
    /// without a timer or a periodic redraw loop.
    @MainActor
    public func rendererPresentationReadinessDidChange() {
        guard rendererPortalVisible, isRendererPresentationReady else { return }

        let geometry = TerminalRendererPresentationGeometry(committedPaneGeometry)
        let decision = TerminalRendererPresentationReadinessDecision(
            previous: rendererPresentationState.readinessGeometry,
            current: geometry,
            renderHealth: renderHealth,
            hasInFlightToken: rendererPresentationState.inFlightToken != nil
        )
        if decision.geometryChanged {
            rendererPresentationState.readinessGeometry = geometry
            rendererPresentationState.recoveryAttempted = false
            if decision.shouldAwaitFrame {
                renderHealth = .awaitingFrame
            }
        }
        ensureRendererPresented(presentationReady: true)
    }
}
