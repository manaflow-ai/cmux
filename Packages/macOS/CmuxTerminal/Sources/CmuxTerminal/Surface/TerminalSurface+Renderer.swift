public import AppKit
public import Foundation
public import GhosttyKit

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

    /// Whether this surface currently holds realized GPU renderer resources.
    /// Read by `RendererRealizationController` to skip surfaces with nothing to
    /// release. Requires a live runtime surface because the presentation phase
    /// is also initialized before the native surface is created.
    public var isRendererRealized: Bool {
        surface != nil && rendererPresentationPhase.isNativeRendererRealized
    }

    /// Whether the current runtime renderer has completed cmux's presentation transition.
    public var isRendererPresented: Bool {
        surface != nil && rendererPresentationPhase == .presented
    }

    /// Whether this surface's portal is currently visible in the UI. This is the
    /// authoritative on-screen signal (the same one that drives occlusion via
    /// `setVisibleInUI`), so the reclamation controller never releases a visible
    /// surface even if higher-level layout bookkeeping is momentarily stale.
    public var isRendererPortalVisible: Bool { rendererPortalVisible }

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
            surfaceCallbackContext?.takeUnretainedValue().cancelRendererPresentationRepair()
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
    /// A visible birth is already attached to its presentation window and can be
    /// marked presented without a redundant native realization cycle.
    @MainActor
    func rendererRuntimeSurfaceDidCreate() {
        rendererRuntimeSurfaceDidCreate(
            presentationReady: isRendererPresentationReady
        )
    }

    @MainActor
    func rendererRuntimeSurfaceDidCreate(presentationReady: Bool) {
        rendererPresentationPhase = .awaitingFirstPresentation
        surfaceCallbackContext?.takeUnretainedValue().cancelRendererPresentationRepair()
        guard surface != nil else { return }
        if rendererPortalVisible, presentationReady {
            rendererPresentationPhase = .presented
            setOcclusion(true)
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
        guard !rendererPortalVisible || !isRendererPresentationReady else { return false }
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
            surfaceCallbackContext?.takeUnretainedValue().cancelRendererPresentationRepair()
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
        guard rendererPresentationPhase != .presented else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.ensurePresented") else { return }
        let callbackContext = surfaceCallbackContext?.takeUnretainedValue()

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
            setOcclusion(true)
        }
#endif
    }

    /// Make sure this surface's renderer is actually producing frames.
    ///
    /// A surface that lives in a window that has never been key — a mirror
    /// viewer window opened behind Settings, or a manual-IO display pane the
    /// user never focuses — can have live terminal state and a realized view
    /// yet draw nothing: `setFocus(true)` is the only path that asserts the
    /// display id, so Ghostty's per-surface display link may never start.
    /// This re-realizes a released renderer, asserts the display id from the
    /// view's current screen so the display link can start without a focus
    /// event, and requests a refresh.
    @MainActor
    public func ensureRendererDrawing() {
#if os(macOS)
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.ensureDrawing") else { return }
        // Current renderer lifecycle uses the presentation phase rather than
        // the old boolean `rendererRealized` mirror. If this surface was
        // reclaimed (or born hidden), publish the guarded rebuild once the
        // portal has usable drawable geometry; an already-presented renderer
        // only needs the display-link/focus nudge below.
        if rendererPresentationPhase != .presented {
            ensureRendererPresented(presentationReady: isRendererPresentationReady)
        }
        if let view = attachedView,
           let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }
        // Ghostty renderers start `focused = true` with the display link
        // running, and a running link means draws happen ONLY on its vsync
        // callbacks. A surface that never receives a focus event (a mirror
        // display pane is never first responder) can therefore sit on a dead
        // link forever: refreshes are consumed but nothing is drawn. Force a
        // focus transition to leave that state — unfocused renderers stop the
        // link and draw change-driven; a genuinely focused pane gets the link
        // restarted on the display id asserted above.
        ghostty_surface_set_focus(surface, false)
        if desiredFocusState {
            ghostty_surface_set_focus(surface, true)
        }
        ghostty_surface_refresh(surface)
#endif
    }

    /// One-line renderer-state summary for the `hive.render_probe` debug RPC:
    /// runtime/realized/visibility flags, manual-IO, the live grid and pixel
    /// size, and the display id the surface's window resolves to.
    @MainActor
    public func rendererDebugSummary() -> String {
        var size = "none"
        if let surface = liveSurfaceForGhosttyAccess(reason: "renderer.debugSummary") {
            let s = ghostty_surface_size(surface)
            size = "\(s.columns)x\(s.rows)@\(s.width_px)x\(s.height_px)px"
        }
        var display = "none"
        if let view = attachedView, let id = view.window?.screen?.displayID {
            display = "\(id)"
        }
        return "runtime=\(surface != nil ? 1 : 0) realized=\(isRendererRealized ? 1 : 0) "
            + "portalVisible=\(rendererPortalVisible ? 1 : 0) manualIO=\(ioMode.usesManualIO ? 1 : 0) "
            + "focusDesired=\(desiredFocusState ? 1 : 0) size=\(size) display=\(display)"
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
              rendererPresentationPhase != .presented else { return }
        ensureRendererPresented(presentationReady: presentationReady)
    }
}
