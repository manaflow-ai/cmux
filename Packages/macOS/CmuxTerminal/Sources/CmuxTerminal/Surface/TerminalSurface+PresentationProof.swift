public import Foundation
internal import AppKit
internal import GhosttyKit
internal import os

nonisolated private let rendererProofLogger = Logger(
    subsystem: "com.cmuxterm.app", category: "TerminalRenderHealth"
)

extension TerminalSurface {
    @MainActor
    var currentRendererPresentationTarget: TerminalRendererPresentationTarget {
        TerminalRendererPresentationTarget(
            runtimeGeneration: runtimeSurfaceGeneration,
            portalGeneration: portalBindingGeneration(),
            host: activePortalHostLease?.hostId,
            hostInstance: activePortalHostLease?.instanceSerial,
            window: uiWindow.map(ObjectIdentifier.init),
            nativeWindow: surfaceView.window.map(ObjectIdentifier.init),
            layer: surfaceView.layer.map(ObjectIdentifier.init),
            paneFrame: paneHost.convert(paneHost.bounds, to: nil),
            nativeFrame: surfaceView.convert(surfaceView.bounds, to: nil),
            backingScale: uiWindow?.backingScaleFactor ?? 1,
            contentRevision: rendererPresentationState.contentRevision
        )
    }

    /// Reports only a frame requested after the owner's manual-output boundary.
    @MainActor
    public var onManualOutputPresented: (@MainActor (UInt64) -> Void)? {
        get { rendererPresentationState.onManualOutputPresented }
        set { rendererPresentationState.onManualOutputPresented = newValue }
    }

    /// Requests proof after all remote output already submitted by this owner.
    /// The request travels on the parser's existing FIFO lane, so an empty
    /// first frame cannot acknowledge a replay still waiting to be parsed.
    @MainActor
    @discardableResult
    public func requestManualOutputPresentation() -> UInt64 {
        rendererPresentationState.contentRevision &+= 1
        if renderHealth != .shellExited { renderHealth = .awaitingFrame }
        if isRendererEffectivelyVisible { ensureRendererPresented() }
        return rendererPresentationState.contentRevision
    }

    @MainActor
    func requestRendererPresentationProbe(reason: String) {
        guard isRendererEffectivelyVisible,
              rendererPresentationPhase == .presented,
              let surface = liveSurfaceForGhosttyAccess(reason: "renderer.probe.\(reason)"),
              let probe = rendererPresentationState.begin(target: currentRendererPresentationTarget) else { return }
        if ioMode.usesManualIO {
            let target = TerminalSurfaceCallbackTarget(surface: self)
            let admitted = remoteOutputLane.enqueuePresentationProbe(probe.token, to: surface) { accepted in
                Task { @MainActor in
                    target.surface?.rendererProbeAdmissionCompleted(token: probe.token, accepted: accepted)
                }
            }
            if !admitted { rendererProbeAdmissionCompleted(token: probe.token, accepted: false) }
        } else {
            rendererProbeAdmissionCompleted(
                token: probe.token,
                accepted: ghostty_surface_request_render_with_token(surface, probe.token)
            )
        }
    }

    @MainActor
    private func rendererProbeAdmissionCompleted(token: UInt64, accepted: Bool) {
        guard !accepted, let probe = rendererPresentationState.take(token: token) else { return }
        guard probe.target.runtimeGeneration == runtimeSurfaceGeneration,
              hasLiveSurface, isRendererEffectivelyVisible else { return }
        guard rendererPresentationState.isCurrent(probe, target: currentRendererPresentationTarget) else {
            ensureRendererPresented()
            return
        }
        markRendererNotRendering(reason: "probeRejected")
        recoverRendererPresentationIfNeeded(reason: "probeRejected")
    }

    @MainActor
    func rendererFrameDidPresent(token: UInt64) {
        guard let probe = rendererPresentationState.take(token: token),
              probe.target.runtimeGeneration == runtimeSurfaceGeneration,
              hasLiveSurface else { return }
        guard isRendererEffectivelyVisible, rendererPresentationPhase != .released else { return }
        guard rendererPresentationState.isCurrent(probe, target: currentRendererPresentationTarget) else {
            if renderHealth != .shellExited { renderHealth = .awaitingFrame }
            ensureRendererPresented()
            return
        }
        rendererPresentationState.acknowledge(probe)
        rendererPresentationPhase = .presented
        if renderHealth != .shellExited { renderHealth = .rendering }
        surfaceCallbackContext?.takeUnretainedValue().cancelRendererPresentationRepair()
        if probe.target.contentRevision > 0 { onManualOutputPresented?(probe.target.contentRevision) }
    }

    @MainActor
    func rendererFrameDidFail(token: UInt64, status: ghostty_render_presentation_status_e) {
        guard let probe = rendererPresentationState.take(token: token),
              probe.target.runtimeGeneration == runtimeSurfaceGeneration,
              hasLiveSurface else { return }
        guard isRendererEffectivelyVisible, rendererPresentationPhase != .released else { return }
        guard rendererPresentationState.isCurrent(probe, target: currentRendererPresentationTarget) else {
            if renderHealth != .shellExited { renderHealth = .awaitingFrame }
            ensureRendererPresented()
            return
        }
        markRendererNotRendering(reason: "probeFailed.\(status.rawValue)")
        recoverRendererPresentationIfNeeded(reason: "probeFailed.\(status.rawValue)")
    }

    @MainActor
    private func markRendererNotRendering(reason: String) {
        guard renderHealth != .shellExited else { return }
        renderHealth = .notRendering
        rendererProofLogger.error("surface.render.notRendering surface=\(self.id.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
    }

    @MainActor
    private func recoverRendererPresentationIfNeeded(reason: String) {
        guard renderHealth != .shellExited, isRendererEffectivelyVisible,
              rendererPresentationPhase == .presented,
              let surface = liveSurfaceForGhosttyAccess(reason: "renderer.recover.\(reason)"),
              rendererPresentationState.beginRecovery(for: currentRendererPresentationTarget) else { return }
        // Publish the existing asynchronous rebuild transaction. A main-thread
        // forceRefresh can enter native drawing and block behind the renderer.
        guard ghostty_surface_rebuild_renderer(surface) else { return }
        renderHealth = .awaitingFrame
        requestRendererPresentationProbe(reason: "recovery.\(reason)")
    }
}
