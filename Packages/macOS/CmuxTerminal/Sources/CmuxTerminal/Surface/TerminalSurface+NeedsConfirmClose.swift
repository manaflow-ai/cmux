internal import GhosttyKit

// MARK: - Close-confirmation queries

extension TerminalSurface {
    /// Whether closing this surface should ask for confirmation.
    ///
    /// Synchronous query used by the close/quit confirmation prompts (rare,
    /// user-initiated). `ghostty_surface_needs_confirm_quit` takes the surface's
    /// `renderer_state` mutex, so it must not be called on a hot or periodic
    /// main-thread path — see ``snapshotNeedsConfirmClose()`` for the
    /// session-snapshot path.
    public func needsConfirmClose() -> Bool {
#if DEBUG
        if let closeConfirmationOverride {
            return closeConfirmationOverride
        }
#endif
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Lock-free close-confirmation estimate for the session-snapshot / autosave
    /// path, which must never block the main thread on the surface's renderer
    /// mutex.
    ///
    /// The autosave tick walks every panel on the main thread and, via
    /// `Workspace.sessionPanelSnapshot`, needs each terminal's close-confirmation
    /// state. Using ``needsConfirmClose()`` there parked the main thread in
    /// `_os_unfair_lock_lock_slow` -> `__ulock_wait2` forever whenever a surface's
    /// renderer/io thread was wedged holding `renderer_state.mutex`, beach-balling
    /// the whole app with no recovery short of `kill -9`
    /// (https://github.com/manaflow-ai/cmux/issues/6381).
    ///
    /// `ghostty_surface_process_exited` reads the `child_exited` field directly
    /// and never takes that mutex, so it can never wedge. It is exactly the value
    /// `Surface.needsConfirmQuit()` reduces to for the only case this feeds:
    /// `Workspace.resolveCloseConfirmation` consults this fallback only when
    /// cmux's own `panelShellActivityState` is `.unknown` (a terminal without
    /// shell-integration prompt markers), where ghostty's own answer is
    /// `!child_exited`. A live child still needs confirmation; an exited one does
    /// not.
    public func snapshotNeedsConfirmClose() -> Bool {
        guard let surface = surface else { return false }
        return !ghostty_surface_process_exited(surface)
    }
}
