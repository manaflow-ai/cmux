internal import Foundation
internal import GhosttyKit
internal import os
#if DEBUG
internal import CMUXDebugLog
#endif

nonisolated private let rendererHealthLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "terminal.render"
)

extension TerminalSurface {
    /// Requests a fresh native frame and waits for its host-layer acknowledgement.
    ///
    /// The returned token identifies an actual presentation after this request,
    /// independent of the renderer's choice of backing layer. Callers arriving
    /// during a draw share the next requested frame. Cancellation, hide, teardown, or a
    /// failed presentation returns nil; callers may impose their own deadline.
    /// - Returns: The acknowledged presentation token, or nil if interrupted.
    @MainActor
    public func waitForPresentedFrame() async -> UInt64? {
        let id = UUID()
        let target = TerminalSurfaceCallbackTarget(surface: self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isRendererEffectivelyVisible, hasLiveSurface else {
                    continuation.resume(returning: nil)
                    return
                }
                ensureRendererPresented()
                rendererPresentationState.queuedFrameWaiters[id] = continuation
                startQueuedFramePresentation()
            }
        } onCancel: {
            Task { @MainActor in
                target.surface?.rendererPresentationState.cancelFrameWaiter(id)
            }
        }
    }

    /// Ghostty accepts one tokened draw at a time. Queue later waiters behind
    /// that draw so they cannot consume a frame requested before their work.
    @MainActor
    private func startQueuedFramePresentation() {
        guard rendererPresentationState.inFlightToken == nil,
              !rendererPresentationState.queuedFrameWaiters.isEmpty else { return }
        rendererPresentationState.frameWaiters = rendererPresentationState.queuedFrameWaiters
        rendererPresentationState.queuedFrameWaiters.removeAll()
        if !requestRendererPresentationProbe(reason: "frame.wait") {
            rendererPresentationState.completeFrameWaiters(nil)
        }
    }

    /// Starts one exact host-layer presentation probe for the current runtime.
    /// Ghostty owns the renderer wakeup; no app timer or second draw loop is
    /// needed to determine whether the first frame reached the pane.
    @discardableResult
    @MainActor
    func requestRendererPresentationProbe(reason: String) -> Bool {
#if os(macOS)
        guard rendererPortalVisible,
              rendererWindowVisible,
              rendererPresentationPhase == .presented,
              let surface = liveSurfaceForGhosttyAccess(reason: "renderer.probe.\(reason)"),
              rendererPresentationState.inFlightToken == nil else { return false }

        rendererPresentationState.token &+= 1
        let token = rendererPresentationState.token
        rendererPresentationState.inFlightToken = token
        guard ghostty_surface_request_render_with_token(
            surface,
            token
        ) else {
            rendererPresentationState.inFlightToken = nil
            rendererPresentationState.completeFrameWaiters(nil)
            markRendererNotRendering(reason: "probeRejected.\(reason)")
            recoverRendererPresentationIfNeeded(reason: "probeRejected.\(reason)")
            return false
        }
#if DEBUG
        logDebugEvent(
            "surface.render.probe surface=\(id.uuidString.prefix(8)) " +
            "token=\(token) reason=\(reason)"
        )
#endif
        return true
#else
        return false
#endif
    }

    /// Called by the exact tokened host-layer callback.
    @MainActor
    func rendererFrameDidPresent(token: UInt64) {
        guard rendererPresentationState.inFlightToken == token else { return }
        rendererPresentationState.inFlightToken = nil
        guard rendererPortalVisible, rendererWindowVisible,
              rendererPresentationPhase != .released else {
            rendererPresentationState.completeFrameWaiters(nil)
            return
        }
        rendererPresentationState.recoveryAttempted = false
        rendererPresentationState.didPresentFrame = true
        rendererPresentationPhase = .presented
        if renderHealth != .shellExited {
            renderHealth = .rendering
        }
        rendererPresentationState.completeActiveFrameWaiters(token)
        startQueuedFramePresentation()
        let callbackContext = surfaceCallbackContext?.takeUnretainedValue()
        callbackContext?.cancelRendererPresentationRepair()
#if DEBUG
        logDebugEvent(
            "surface.render.presented surface=\(id.uuidString.prefix(8)) token=\(token)"
        )
#endif
    }

    /// Called when Ghostty discarded or failed the exact tokened frame.
    @MainActor
    func rendererFrameDidFail(
        token: UInt64,
        status: ghostty_render_presentation_status_e
    ) {
        guard rendererPresentationState.inFlightToken == token else { return }
        guard rendererWindowVisible else {
            rendererPresentationState.inFlightToken = nil
            rendererPresentationState.completeFrameWaiters(nil)
            if renderHealth != .shellExited {
                renderHealth = .notStarted
            }
            return
        }
        rendererPresentationState.inFlightToken = nil
        rendererPresentationState.completeFrameWaiters(nil)
        guard rendererPortalVisible else {
            if renderHealth != .shellExited {
                renderHealth = .notStarted
            }
            return
        }
        markRendererNotRendering(reason: "probeFailed.\(status.rawValue)")
        recoverRendererPresentationIfNeeded(reason: "probeFailed.\(status.rawValue)")
    }

    @MainActor
    private func markRendererNotRendering(reason: String) {
        guard renderHealth != .shellExited else { return }
        renderHealth = .notRendering
        rendererHealthLogger.error(
            "surface.render.notRendering surface=\(self.id.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
        )
#if DEBUG
        logDebugEvent(
            "surface.render.notRendering surface=\(id.uuidString.prefix(8)) reason=\(reason) " +
            "portal=\(rendererPortalVisible ? 1 : 0) window=\(rendererWindowVisible ? 1 : 0)"
        )
#endif
    }

    @MainActor
    private func recoverRendererPresentationIfNeeded(reason: String) {
        guard renderHealth != .shellExited,
              !rendererPresentationState.recoveryAttempted,
              rendererPortalVisible,
              rendererPresentationPhase == .presented,
              liveSurfaceForGhosttyAccess(reason: "renderer.recover.\(reason)") != nil else {
            return
        }
        rendererPresentationState.recoveryAttempted = true
        forceRefresh(reason: "renderer.recover.\(reason)")
        renderHealth = .awaitingFrame
        requestRendererPresentationProbe(reason: "recovery.\(reason)")
    }

    /// Records that the child process has exited while retaining the pane for
    /// inspection. A later runtime replacement resets this state.
    @MainActor
    public func markShellExited() {
        rendererPresentationState.inFlightToken = nil
        rendererPresentationState.completeFrameWaiters(nil)
        renderHealth = .shellExited
        rendererHealthLogger.notice(
            "surface.render.shellExited surface=\(self.id.uuidString, privacy: .public)"
        )
#if DEBUG
        logDebugEvent("surface.render.shellExited surface=\(id.uuidString.prefix(8))")
#endif
    }
}
