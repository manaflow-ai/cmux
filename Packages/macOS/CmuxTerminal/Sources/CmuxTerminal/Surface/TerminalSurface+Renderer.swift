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

    /// Applies the occlusion state to the runtime surface.
    public func setOcclusion(_ visible: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// Whether this surface currently holds realized GPU renderer resources.
    /// Read by `RendererRealizationController` to skip surfaces with nothing to
    /// release. Requires a live runtime surface — the `rendererRealized` flag
    /// defaults to `true` even before `createSurface`, so gate on `surface`.
    public var isRendererRealized: Bool { surface != nil && rendererRealized }

    /// Whether this surface's portal is currently visible in the UI. This is the
    /// authoritative on-screen signal (the same one that drives occlusion via
    /// `setVisibleInUI`), so the reclamation controller never releases a visible
    /// surface even if higher-level layout bookkeeping is momentarily stale.
    public var isRendererPortalVisible: Bool { rendererPortalVisible }

    /// Record the portal visibility transition for reclamation. Called from
    /// `setVisibleInUI`. Stamps the LRU/idle timestamp on BOTH transitions: a
    /// hide moment is the surface's last-visible time, so the planner's
    /// `now - rendererLastVisibleAt` measures the true offscreen-idle duration
    /// from the hide rather than from the last sampling tick (which could reclaim
    /// the renderer well before `idleSeconds` of being offscreen has elapsed).
    public func setRendererPortalVisible(_ visible: Bool) {
        let wasVisible = rendererPortalVisible
        rendererPortalVisible = visible
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

    /// Release the runtime surface's GPU renderer (Metal swap chain / IOSurface)
    /// while keeping its PTY/io thread and terminal state alive. Driven by
    /// `RendererRealizationController` for offscreen, idle surfaces. Idempotent:
    /// no-ops if there is no runtime surface, it is already released, or the
    /// surface is currently visible (a hard safety net so we never blank an
    /// on-screen terminal regardless of how the caller picked it).
    @discardableResult
    @MainActor
    public func releaseRenderer() -> Bool {
#if os(macOS)
        guard rendererRealized, !rendererPortalVisible else { return false }
        // The reclamation controller is default-on and scans every registered
        // wrapper, so validate the native pointer (registry ownership +
        // liveness) before the C call instead of trusting `surface != nil`.
        // This self-heals a stale wrapper whose runtime surface was freed
        // out-of-band rather than passing a dangling pointer to Ghostty.
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.release") else { return false }
        // Only advance our mirror state when the message was actually enqueued
        // (a `.forever` push can still drop on a spurious wakeup while the
        // mailbox is full). If it dropped, keep `rendererRealized = true` so the
        // controller retries on its next pass rather than desyncing from
        // Ghostty's still-realized swap chain.
        if ghostty_surface_set_renderer_realized(surface, false) {
            rendererRealized = false
            return true
        }
        return false
#else
        return false
#endif
    }

    /// Recreate the runtime surface's GPU renderer after a prior `releaseRenderer`.
    /// Must run before the surface is drawn again (it is called from
    /// `setVisibleInUI(true)` before occlusion/refresh). Idempotent: no-ops if
    /// there is no runtime surface or it is already realized, so it never trips
    /// Ghostty's `displayRealized` `assert(swap_chain.defunct)`.
    @MainActor
    public func realizeRenderer() {
#if os(macOS)
        guard !rendererRealized else { return }
        // Validate the native pointer before the C call (see releaseRenderer).
        // If the wrapper is stale this returns nil and tears it down; the next
        // createSurface re-creates a fresh realized surface, so we never
        // double-realize a defunct swap chain.
        guard let surface = liveSurfaceForGhosttyAccess(reason: "renderer.realize") else { return }
        // Non-blocking enqueue (the C API pushes `.instant`): advance our mirror
        // state only on success. On re-show the renderer mailbox is normally
        // empty, so the realize enqueues immediately and the surface is never
        // presented against a defunct swap chain. In the rare full-mailbox case
        // the push drops, `rendererRealized` stays false, and the controller's
        // pass re-realizes any visible-but-unrealized surface as the backstop. We
        // never block the main actor waiting on the renderer thread.
        if ghostty_surface_set_renderer_realized(surface, true) {
            rendererRealized = true
        } else {
            // Enqueue dropped (full mailbox, i.e. the renderer thread is not
            // draining). Kick an immediate reclamation pass so the controller
            // re-realizes this now-visible surface on the next runloop turn
            // instead of waiting for the periodic tick, minimizing how long a
            // re-shown terminal could draw against a defunct swap chain.
            rendererRealization.scheduleImmediatePass()
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
        realizeRenderer()
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
        return "runtime=\(surface != nil ? 1 : 0) realized=\(rendererRealized ? 1 : 0) "
            + "portalVisible=\(rendererPortalVisible ? 1 : 0) manualIO=\(manualIO ? 1 : 0) "
            + "focusDesired=\(desiredFocusState ? 1 : 0) size=\(size) display=\(display)"
    }
}
