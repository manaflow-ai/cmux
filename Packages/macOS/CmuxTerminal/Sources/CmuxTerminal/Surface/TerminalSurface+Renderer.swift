public import AppKit
public import Foundation
public import GhosttyKit
public import CmuxTerminalRenderTransport

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
        enqueueRenderMutation(.focus(focused))
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
        enqueueRenderMutation(.focus(focused))

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
        enqueueRenderMutation(.occlusion(visible))
    }

    /// Whether this surface currently holds realized GPU renderer resources.
    /// Read by `RendererRealizationController` to skip surfaces with nothing to
    /// release. Requires a live runtime surface — the `rendererRealized` flag
    /// defaults to `true` even before `createSurface`, so gate on `surface`.
    public var isRendererRealized: Bool { renderMirrorDescriptor != nil && rendererRealized }

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
        guard renderMirrorDescriptor != nil else { return false }
        enqueueRenderMutation(.rendererRealized(false))
        rendererRealized = false
        return true
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
        guard renderMirrorDescriptor != nil else { return }
        enqueueRenderMutation(.rendererRealized(true))
        rendererRealized = true
#endif
    }

    func enqueueRenderMutation(_ mutation: TerminalRenderSurfaceMutation) {
        guard let descriptor = renderMirrorDescriptor else { return }
        renderWorker.enqueueRenderCommand(.mutateSurface(
            id: id,
            generation: descriptor.generation,
            mutation: mutation
        ))
    }

    /// Mirrors the host appearance into the worker-owned renderer.
    public func setRenderColorScheme(_ rawValue: Int32) {
        enqueueRenderMutation(.colorScheme(rawValue))
    }

    public func mirrorRenderPreedit(
        _ text: String?,
        selectionStart: Int,
        selectionLength: Int
    ) {
        enqueueRenderMutation(.preedit(
            text: text,
            selectionStart: selectionStart,
            selectionLength: selectionLength
        ))
    }

    public func mirrorRenderMousePosition(x: Double, y: Double, modifiers: UInt32) {
        enqueueRenderMutation(.mousePosition(x: x, y: y, modifiers: modifiers))
    }

    public func mirrorRenderMouseButton(state: Int32, button: Int32, modifiers: UInt32) {
        enqueueRenderMutation(.mouseButton(
            state: state,
            button: button,
            modifiers: modifiers
        ))
    }

    public func mirrorRenderMouseScroll(deltaX: Double, deltaY: Double, modifiers: UInt32) {
        enqueueRenderMutation(.mouseScroll(
            deltaX: deltaX,
            deltaY: deltaY,
            modifiers: modifiers
        ))
    }

    public func clearRenderSelection() {
        enqueueRenderMutation(.clearSelection)
    }

    @MainActor
    func updateRenderMirrorSize(width: UInt32, height: UInt32) {
        guard let descriptor = renderMirrorDescriptor else { return }
        renderMirrorDescriptor = TerminalRenderSurfaceDescriptor(
            id: descriptor.id,
            generation: descriptor.generation,
            width: width,
            height: height,
            scaleX: descriptor.scaleX,
            scaleY: descriptor.scaleY,
            fontSize: descriptor.fontSize,
            context: descriptor.context
        )
        enqueueRenderMutation(.resize(width: width, height: height))
        surfaceView.updateRemoteRendererExpectedSize(width: width, height: height)
    }

    @MainActor
    func updateRenderMirrorScale(x: Double, y: Double) {
        guard let descriptor = renderMirrorDescriptor else { return }
        renderMirrorDescriptor = TerminalRenderSurfaceDescriptor(
            id: descriptor.id,
            generation: descriptor.generation,
            width: descriptor.width,
            height: descriptor.height,
            scaleX: x,
            scaleY: y,
            fontSize: descriptor.fontSize,
            context: descriptor.context
        )
        enqueueRenderMutation(.contentScale(x: x, y: y))
    }

    func destroyRenderMirror() {
        guard let descriptor = renderMirrorDescriptor else { return }
        renderMirrorDescriptor = nil
        rendererRealized = false
        renderWorker.enqueueRenderCommand(.destroySurface(
            id: descriptor.id,
            generation: descriptor.generation
        ))
    }

    /// Updates the view's frame fence after the worker or this mirror becomes ready.
    @MainActor
    public func renderWorkerDidBecomeReady(workerGeneration: UInt64) {
        guard renderMirrorDescriptor != nil else { return }
        surfaceView.updateRemoteRendererWorkerGeneration(workerGeneration)
    }

    /// Retains the last frame while fencing messages from an exited worker.
    @MainActor
    public func renderWorkerDidExit(workerGeneration: UInt64) {
        surfaceView.invalidateRemoteRendererWorkerGeneration(workerGeneration)
    }

    /// Hands an imported IOSurface to the main-actor presentation layer.
    @MainActor
    public func acceptRenderWorkerFrame(_ frame: TerminalRenderFrame) {
        _ = surfaceView.presentRemoteRendererFrame(frame)
    }
}
