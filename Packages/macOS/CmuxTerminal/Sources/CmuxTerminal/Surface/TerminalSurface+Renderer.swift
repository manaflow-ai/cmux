public import AppKit
public import Foundation
public import GhosttyKit
internal import os
#if DEBUG
internal import CMUXDebugLog
#endif

private let rendererHealthLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "terminal.render"
)

// MARK: - Focus, occlusion, and renderer reclamation

extension TerminalSurface {
    /// Re-applies the active window background through the surface view.
    @MainActor
    public func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    /// Keep `desiredFocusState` in sync when the hosted view's responder chain
    /// calls `ghostty_surface_set_focus` directly (bypassing `setFocus`).
    /// Without this, `createSurface` would replay a stale state on recreation.
    public func recordExternalFocusState(_ focused: Bool) {
        desiredFocusState = focused
    }

    /// Applies a focus state to the runtime surface (deduplicated).
    @MainActor
    public func setFocus(_ focused: Bool, force: Bool = false) {
        if !focused {
            surfaceView.cancelKeyboardCopyMode()
        }
        // Only send focus events when the state changes to avoid redundant
        // prompt redraws with zsh themes like Powerlevel10k.
        guard force || focused != desiredFocusState else { return }
        desiredFocusState = focused
        // Track desired state even before the C surface exists (e.g. during
        // layout restoration). createSurface syncs the state once created.
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)

        // If we focus a surface while it is being rapidly reparented (closing splits, etc),
        // Ghostty's CVDisplayLink can end up started before the display id is valid, leaving
        // hasVsync() true but with no callbacks ("stuck-vsync-no-frames"). Reasserting the
        // display id *after* focusing lets Ghostty restart the display link when needed.
        if focused {
            if let view = attachedView,
               let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    /// Applies the occlusion state to the runtime surface.
    public func setOcclusion(_ visible: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// Applies a visibility-derived occlusion request (portal reveal, canvas
    /// viewport entry), folding in the hosting window's on-screen state so a
    /// hidden window can never be un-occluded by a layout transition. Raw
    /// `setOcclusion` remains for renderer presentation transactions.
    @MainActor
    public func applyVisibilityOcclusion(_ visible: Bool) {
        setOcclusion(visible && rendererWindowVisible)
    }

    /// Whether this surface currently holds realized GPU renderer resources.
    /// Read by `RendererRealizationController` to skip surfaces with nothing to
    /// release. Requires a live runtime surface because the presentation phase
    /// is also initialized before the native surface is created.
    public var isRendererRealized: Bool {
        surface != nil && rendererPresentationPhase.isNativeRendererRealized
    }

    /// Whether the current runtime renderer has delivered a frame to its host layer.
    public var isRendererPresented: Bool {
        guard surface != nil, rendererPresentationPhase == .presented else { return false }
        return renderHealth == .rendering
            || (renderHealth == .shellExited && rendererPresentationState.didPresentFrame)
    }

    /// Whether this surface's portal is currently visible in the UI. This is the
    /// authoritative on-screen signal (the same one that drives occlusion via
    /// `setVisibleInUI`), so the reclamation controller never releases a visible
    /// surface even if higher-level layout bookkeeping is momentarily stale.
    public var isRendererPortalVisible: Bool { rendererPortalVisible }

    /// Whether the surface can actually be seen: its portal is visible inside a
    /// window that is itself visible on screen. This is the signal that gates
    /// occlusion, presentation, and renderer reclamation, so the visible tab of
    /// a miniaturized or fully covered window is treated the same as a hidden
    /// tab (no draw cadence, reclaimable GPU swap chain).
    public var isRendererEffectivelyVisible: Bool {
        rendererPortalVisible && rendererWindowVisible
    }

    /// Applies the hosting window's on-screen visibility. Mirrors the portal
    /// path: a hide stamps the surface's last-visible moment for reclamation
    /// and occludes the core surface; a show lifts occlusion, or replays the
    /// presentation transition when the renderer was reclaimed while hidden.
    @MainActor
    public func setRendererWindowVisible(_ visible: Bool) {
        guard visible != rendererWindowVisible else { return }
        rendererWindowVisible = visible
        // A hidden portal already has occlusion false and a stamped hide time;
        // window transitions only matter for the surfaces the portal shows.
        guard rendererPortalVisible else { return }
        noteBecameVisibleForRendererReclamation()
        if visible {
            if rendererPresentationPhase == .presented, renderHealth == .rendering {
                setOcclusion(true)
            } else {
                ensureRendererPresented()
            }
        } else {
            rendererPresentationState.recoveryAttempted = false
            setOcclusion(false)
        }
    }

    /// Whether the native surface view and its pane host have usable drawable
    /// geometry in the same real presentation window. A hidden bootstrap window
    /// can start the PTY, and a zero-sized real-window attachment can establish
    /// ownership, but neither is enough to present a renderer.
    @MainActor
    private var isRendererPresentationReady: Bool {
        guard let attachedView,
              let presentationWindow = uiWindow,
              attachedView.window === presentationWindow else { return false }
        let surfaceSize = attachedView.bounds.size
        let paneSize = paneHost.bounds.size
        return surfaceSize.width.isFinite && surfaceSize.height.isFinite &&
            paneSize.width.isFinite && paneSize.height.isFinite &&
            surfaceSize.width > 1 && surfaceSize.height > 1 &&
            paneSize.width > 1 && paneSize.height > 1
    }

    /// Record the portal visibility transition for reclamation. Called from
    /// `setVisibleInUI`. Stamps the LRU/idle timestamp on BOTH transitions: a
    /// hide moment is the surface's last-visible time, so the planner's
    /// `now - rendererLastVisibleAt` measures the true offscreen-idle duration
    /// from the hide rather than from the last sampling tick (which could reclaim
    /// the renderer well before `idleSeconds` of being offscreen has elapsed).
    @MainActor
    public func setRendererPortalVisible(_ visible: Bool) {
        setRendererPortalVisible(
            visible,
            presentationReady: isRendererPresentationReady
        )
    }

    @MainActor
    func setRendererPortalVisible(_ visible: Bool, presentationReady: Bool) {
        let wasVisible = rendererPortalVisible
        rendererPortalVisible = visible
        if !visible {
            rendererPresentationState.inFlightToken = nil
            rendererPresentationState.recoveryAttempted = false
            if renderHealth != .shellExited {
                renderHealth = .notStarted
            }
            let callbackContext = surfaceCallbackContext?.takeUnretainedValue()
            callbackContext?.cancelRendererPresentationRepair()
        }
        // This is the single presentation transition for both a renderer that
        // was reclaimed and one that was born hidden and never got a drawable.
        // The AppKit host makes the portal presentable first, then calls here
        // while Ghostty is still occluded; occlusion is lifted only after the
        // native rebuild publication below.
        if visible {
            ensureRendererPresented(presentationReady: presentationReady)
        }
        // Stamp the last-visible time while visible, and exactly once at the hide
        // transition (the hide moment is the last-visible time). Do NOT re-stamp
        // on repeated hidden updates (setVisibleInUI can be called many times with
        // visible=false during layout reconciles), or the offscreen-idle clock
        // would keep resetting and the renderer would never be reclaimed.
        if visible || wasVisible {
            noteBecameVisibleForRendererReclamation()
        }
    }

    /// Stamp the LRU "last visible" timestamp. The reclamation controller also
    /// calls this each pass for surfaces that are currently visible so a
    /// continuously-visible tab keeps a fresh timestamp and stays in the warm set.
    public func noteBecameVisibleForRendererReclamation() {
        rendererLastVisibleAt = Date().timeIntervalSince1970
    }

    /// Records a newly created native renderer and normalizes a hidden-at-birth
    /// surface into the same released state used by memory-pressure reclaim.
    /// A visible birth is attached to its presentation window, but remains
    /// awaiting acknowledgement until Ghostty presents its first frame.
    @MainActor
    func rendererRuntimeSurfaceDidCreate() {
        rendererRuntimeSurfaceDidCreate(
            presentationReady: isRendererPresentationReady
        )
    }

    @MainActor
    func rendererRuntimeSurfaceDidCreate(presentationReady: Bool) {
        rendererPresentationPhase = .awaitingFirstPresentation
        rendererPresentationState.inFlightToken = nil
        rendererPresentationState.recoveryAttempted = false
        rendererPresentationState.didPresentFrame = false
        renderHealth = .notStarted
        let callbackContext = surfaceCallbackContext?.takeUnretainedValue()
        callbackContext?.cancelRendererPresentationRepair()
        guard surface != nil else { return }
        if rendererPortalVisible, rendererWindowVisible, presentationReady {
            rendererPresentationPhase = .presented
            renderHealth = .awaitingFrame
            setOcclusion(true)
            requestRendererPresentationProbe(reason: "runtime.create")
        } else {
            // The portal may have become hidden before the native pointer
            // existed, or become visible before AppKit attached it to a real
            // window. Replay occlusion now so Ghostty stops drawing before the
            // renderer-release state makes its swap chain defunct.
            setOcclusion(false)
            _ = releaseRenderer()
        }
    }

    /// Completes a deferred first presentation after AppKit supplies both a real
    /// window and usable drawable geometry. Attachment and sizing paths call this
    /// transition, so a skipped reentrant layout can recover on the next normal
    /// layout pass without forcing the hosting hierarchy to lay out recursively.
    @MainActor
    public func rendererPresentationReadinessDidChange() {
        guard rendererPortalVisible, isRendererPresentationReady else { return }
        ensureRendererPresented(presentationReady: true)
    }

    /// Release the runtime surface's GPU renderer (Metal swap chain / IOSurface)
    /// while keeping its PTY/io thread and terminal state alive. Driven by
    /// `RendererRealizationController` for offscreen, idle surfaces. Idempotent:
    /// no-ops if there is no runtime surface, it is already released, or the
    /// surface is visible in a real presentation window (a hard safety net so
    /// we never blank an on-screen terminal regardless of how the caller picked
    /// it). A portal flagged visible before attachment may be normalized into
    /// the released state so its first real presentation uses the restore path.
    @discardableResult
    @MainActor
    public func releaseRenderer() -> Bool {
#if os(macOS)
        guard rendererPresentationPhase != .released else { return false }
        // A visible portal is protected once it is actually attached. Before
        // that point (including the hidden bootstrap window), release is the
        // normalization step that makes first presentation safe and retryable.
        // A visible portal inside a hidden window is NOT protected: nothing on
        // screen shows it, so its swap chain is reclaimable like a hidden tab's.
        guard !isRendererEffectivelyVisible || !isRendererPresentationReady else { return false }
        // The reclamation controller is default-on and scans every registered
        // wrapper, so validate the native pointer (registry ownership +
        // liveness) before the C call instead of trusting `surface != nil`.
        // This self-heals a stale wrapper whose runtime surface was freed
        // out-of-band rather than passing a dangling pointer to Ghostty.
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.release") else { return false }
        // Only advance our mirror state after the core accepts the authoritative
        // latest-value request. The pinned core accepts it losslessly; retaining
        // the rejection path keeps compatibility shims retryable.
        if ghostty_surface_set_renderer_realized(surface, false) {
            rendererPresentationPhase = .released
            rendererPresentationState.inFlightToken = nil
            if renderHealth != .shellExited {
                renderHealth = .notStarted
            }
            let callbackContext = surfaceCallbackContext?.takeUnretainedValue()
            callbackContext?.cancelRendererPresentationRepair()
            return true
        }
        return false
#else
        return false
#endif
    }

    /// Ensures the runtime renderer is ready for presentation in a visible portal.
    ///
    /// Reclaimed renderers and renderers born hidden use one forced rebuild
    /// transaction. This guarantees Ghostty applies the unrealize transition
    /// before realizing the renderer, even when presentation becomes ready
    /// before the renderer thread consumes an earlier release publication.
    @MainActor
    public func ensureRendererPresented() {
        ensureRendererPresented(
            presentationReady: isRendererPresentationReady
        )
    }

    @MainActor
    func ensureRendererPresented(presentationReady: Bool) {
#if os(macOS)
        // `setVisibleInUI(true)` can precede portal reattachment or completed
        // layout. Do not realize against a windowless/headless/zero-sized layer
        // and then mirror that enqueue as a completed presentation.
        guard presentationReady else { return }
        // A hidden window has nothing to present into; keep the renderer
        // released and let `setRendererWindowVisible(true)` replay this
        // transition when the window comes back on screen.
        guard rendererWindowVisible else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.ensurePresented") else { return }
        let callbackContext = surfaceCallbackContext?.takeUnretainedValue()
        let shellExited = renderHealth == .shellExited

        if rendererPresentationPhase == .presented {
            // Occlusion is a visibility fact even when the previous recovery
            // attempt was exhausted. Restore it before any health guard.
            setOcclusion(true)
            guard renderHealth != .shellExited,
                  !(renderHealth == .notRendering && rendererPresentationState.recoveryAttempted) else {
                return
            }
            if renderHealth != .rendering {
                renderHealth = .awaitingFrame
                requestRendererPresentationProbe(reason: "ensure.presented")
            }
            return
        }

        // A detached visibility update may already have lifted occlusion.
        // Re-occlude synchronously before publishing the renderer rebuild, and
        // lift it only after the core accepts that transaction.
        setOcclusion(false)

        // The C API publishes one non-blocking forced unrealize/realize
        // transaction outside the renderer mailbox. Unlike separate boolean
        // publications, a later realized state cannot coalesce away the
        // unrealize step needed to rebuild a missing first drawable.
        callbackContext?.armRendererPresentationRepair()
        if ghostty_surface_rebuild_renderer(surface) {
            callbackContext?.cancelRendererPresentationRepair()
            rendererPresentationPhase = .presented
            renderHealth = shellExited ? .shellExited : .awaitingFrame
            setOcclusion(true)
            requestRendererPresentationProbe(reason: "renderer.rebuild")
        }
#endif
    }

    /// Retries an unresolved presentation after Ghostty reports renderer activity.
    ///
    /// The app resolves the callback's stable surface id, then calls this only
    /// for that surface. Re-checking lifecycle and visibility here makes a
    /// queued callback harmless after hide, close, or successful presentation.
    @MainActor
    public func retryRendererPresentationAfterActivity() {
        retryRendererPresentationAfterActivity(
            presentationReady: isRendererPresentationReady
        )
    }

    @MainActor
    func retryRendererPresentationAfterActivity(presentationReady: Bool) {
        guard rendererPortalVisible,
              hasLiveSurface,
              (rendererPresentationPhase != .presented || renderHealth != .rendering) else { return }
        ensureRendererPresented(presentationReady: presentationReady)
    }

    /// Starts one exact host-layer presentation probe for the current runtime.
    /// Ghostty owns the renderer wakeup; no app timer or second draw loop is
    /// needed to determine whether the first frame reached the pane.
    @MainActor
    private func requestRendererPresentationProbe(reason: String) {
#if os(macOS)
        guard rendererPortalVisible,
              rendererWindowVisible,
              rendererPresentationPhase == .presented,
              let surface = liveSurfaceForGhosttyAccess(reason: "renderer.probe.\(reason)"),
              rendererPresentationState.inFlightToken == nil else { return }

        rendererPresentationState.token &+= 1
        let token = rendererPresentationState.token
        rendererPresentationState.inFlightToken = token
        guard ghostty_surface_request_render_with_token(
            surface,
            token
        ) else {
            rendererPresentationState.inFlightToken = nil
            markRendererNotRendering(reason: "probeRejected.\(reason)")
            recoverRendererPresentationIfNeeded(reason: "probeRejected.\(reason)")
            return
        }
#if DEBUG
        logDebugEvent(
            "surface.render.probe surface=\(id.uuidString.prefix(8)) " +
            "token=\(token) reason=\(reason)"
        )
#endif
#endif
    }

    /// Called by the exact tokened host-layer callback.
    @MainActor
    func rendererFrameDidPresent(token: UInt64) {
        guard rendererPresentationState.inFlightToken == token,
              rendererPortalVisible,
              rendererWindowVisible,
              rendererPresentationPhase != .released else { return }
        rendererPresentationState.inFlightToken = nil
        rendererPresentationState.recoveryAttempted = false
        rendererPresentationState.didPresentFrame = true
        rendererPresentationPhase = .presented
        if renderHealth != .shellExited {
            renderHealth = .rendering
        }
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
            if renderHealth != .shellExited {
                renderHealth = .notStarted
            }
            return
        }
        rendererPresentationState.inFlightToken = nil
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
        renderHealth = .shellExited
        rendererHealthLogger.notice(
            "surface.render.shellExited surface=\(self.id.uuidString, privacy: .public)"
        )
#if DEBUG
        logDebugEvent("surface.render.shellExited surface=\(id.uuidString.prefix(8))")
#endif
    }
}
