import AppKit

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

        let geometry = committedPaneGeometry
        let geometryChanged = geometry?.size != rendererPresentationState.readinessSize
            || geometry?.backingScale != rendererPresentationState.readinessBackingScale
        if geometryChanged {
            rendererPresentationState.readinessSize = geometry?.size
            rendererPresentationState.readinessBackingScale = geometry?.backingScale
            rendererPresentationState.recoveryAttempted = false
            if rendererPresentationState.inFlightToken == nil,
               renderHealth != .shellExited {
                renderHealth = .awaitingFrame
            }
        }

        ensureRendererPresented(presentationReady: true)
    }
}
