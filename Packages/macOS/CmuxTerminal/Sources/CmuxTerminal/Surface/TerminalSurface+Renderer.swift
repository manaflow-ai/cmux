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

    /// Records the UI visibility axis and applies the effective occlusion.
    public func setOcclusion(_ visible: Bool) {
        occlusionState.uiVisible = visible
        applyOcclusionIfNeeded()
    }

    /// Records the host-window visibility axis and applies the effective occlusion.
    ///
    /// Detach and reparent transients intentionally leave this axis unchanged;
    /// only an attached `NSWindow` occlusion observation should update it.
    public func setWindowOcclusionVisible(_ visible: Bool) {
        occlusionState.windowVisible = visible
        applyOcclusionIfNeeded()
    }

    /// Applies the combined UI/window occlusion state to Ghostty, deduplicated.
    private func applyOcclusionIfNeeded() {
        guard let surface = surface else { return }
        let effectiveVisible = occlusionState.effectiveVisible
        guard lastAppliedOcclusionVisible != effectiveVisible else { return }
        ghostty_surface_set_occlusion(surface, effectiveVisible)
        lastAppliedOcclusionVisible = effectiveVisible
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

    /// Whether the native surface view and its pane host are both attached to
    /// the same real presentation window. A hidden bootstrap window is useful
    /// for starting the PTY, but it cannot safely host the first drawable.
    @MainActor
    private var isRendererPresentationAttachmentReady: Bool {
        return attachedView?.window != nil && uiWindow != nil
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
            attachmentReady: isRendererPresentationAttachmentReady
        )
    }

    @MainActor
    func setRendererPortalVisible(_ visible: Bool, attachmentReady: Bool) {
        let wasVisible = rendererPortalVisible
        rendererPortalVisible = visible
        if !visible {
            surfaceCallbackContext?.takeUnretainedValue().cancelRendererPresentationRepair()
        }
        // This is the single presentation transition for both a renderer that
        // was reclaimed and one that was born hidden and never got a drawable.
        // The AppKit host makes the portal presentable first, then calls here
        // while Ghostty is still occluded; occlusion is lifted only after the
        // native realization enqueue below.
        if visible {
            ensureRendererPresented(attachmentReady: attachmentReady)
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
            attachmentReady: isRendererPresentationAttachmentReady
        )
    }

    @MainActor
    func rendererRuntimeSurfaceDidCreate(attachmentReady: Bool) {
        rendererPresentationPhase = .awaitingFirstPresentation
        surfaceCallbackContext?.takeUnretainedValue().cancelRendererPresentationRepair()
        guard surface != nil else { return }
        if rendererPortalVisible, attachmentReady {
            rendererPresentationPhase = .presented
            setOcclusion(true)
        } else {
            // The portal may have become hidden before the native pointer
            // existed, or become visible before AppKit attached it to a real
            // window. Replay occlusion now so Ghostty stops drawing before the
            // ordered renderer-release message makes its swap chain defunct.
            setOcclusion(false)
            _ = releaseRenderer()
        }
    }

    /// Completes a deferred first presentation after AppKit attaches the pane
    /// to a real window. Both `attachToView` and the already-attached reconcile
    /// path call this so portal reparenting cannot strand a released renderer.
    @MainActor
    func rendererPresentationAttachmentDidBecomeReady() {
        guard rendererPortalVisible, isRendererPresentationAttachmentReady else { return }
        ensureRendererPresented(attachmentReady: true)
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
        guard !rendererPortalVisible || !isRendererPresentationAttachmentReady else { return false }
        // The reclamation controller is default-on and scans every registered
        // wrapper, so validate the native pointer (registry ownership +
        // liveness) before the C call instead of trusting `surface != nil`.
        // This self-heals a stale wrapper whose runtime surface was freed
        // out-of-band rather than passing a dangling pointer to Ghostty.
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.release") else { return false }
        // Only advance our mirror state when the message was actually enqueued
        // (the non-blocking push drops when the mailbox is full). If it dropped,
        // keep the current phase so the
        // controller retries rather than desyncing from Ghostty's live renderer.
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
    /// Reclaimed renderers are realized directly. A renderer born hidden first
    /// transitions through the released state, then uses that same realization
    /// path; this forces Ghostty to build the drawable it could not create while
    /// the view had no real presentation window. Native messages strictly
    /// alternate, so Ghostty's `displayRealized` defunct assertion remains valid.
    @MainActor
    public func ensureRendererPresented() {
        ensureRendererPresented(
            attachmentReady: isRendererPresentationAttachmentReady
        )
    }

    @MainActor
    func ensureRendererPresented(attachmentReady: Bool) {
#if os(macOS)
        // `setVisibleInUI(true)` can precede Dock portal reattachment. Do not
        // realize against a windowless/headless layer and then mirror that
        // enqueue as a completed presentation.
        guard attachmentReady else { return }
        guard rendererPresentationPhase != .presented else { return }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.ensurePresented") else { return }
        let callbackContext = surfaceCallbackContext?.takeUnretainedValue()

        // A detached visibility update may already have lifted occlusion.
        // Re-occlude synchronously before changing renderer realization, and
        // lift it only after the realization enqueue succeeds.
        setOcclusion(false)

        if rendererPresentationPhase == .awaitingFirstPresentation {
            // Ghostty starts with a live renderer even if its view was born
            // hidden. Release it once so first presentation can take the exact
            // same proven restore path as a renderer reclaimed later.
            // Arm before the non-blocking enqueue so a concurrent renderer
            // drain cannot race past the signal that makes this retryable.
            callbackContext?.armRendererPresentationRepair()
            guard ghostty_surface_set_renderer_realized(surface, false) else { return }
            callbackContext?.cancelRendererPresentationRepair()
            rendererPresentationPhase = .released
        }

        // Non-blocking enqueue (the C API pushes `.instant`): advance our mirror
        // state only on success. On re-show the renderer mailbox is normally
        // empty, so the realize enqueues immediately and the surface is never
        // presented against a defunct swap chain. In the rare full-mailbox case
        // the push drops and the armed callback targets this surface after the
        // renderer drains that mailbox. We never block the main actor waiting on
        // the renderer thread.
        callbackContext?.armRendererPresentationRepair()
        if ghostty_surface_set_renderer_realized(surface, true) {
            callbackContext?.cancelRendererPresentationRepair()
            rendererPresentationPhase = .presented
            setOcclusion(true)
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
            attachmentReady: isRendererPresentationAttachmentReady
        )
    }

    @MainActor
    func retryRendererPresentationAfterActivity(attachmentReady: Bool) {
        guard rendererPortalVisible,
              hasLiveSurface,
              rendererPresentationPhase != .presented else { return }
        ensureRendererPresented(attachmentReady: attachmentReady)
    }
}
