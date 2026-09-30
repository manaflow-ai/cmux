internal import GhosttyKit

// MARK: - Close confirmation risk model

extension TerminalSurface {
    func hasCloseConfirmationProcessRisk(_ surface: ghostty_surface_t) -> Bool {
        if hasDeferredStartupWorkForBackgroundStart() { return true }
        if ghostty_surface_foreground_pid(surface) > 0 { return true }
        let exported = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(exported) }
        return exported.ptr != nil && exported.len > 0
    }

    /// Lock-free close-confirmation estimate for the session snapshot / autosave path.
    ///
    /// `ghostty_surface_needs_confirm_quit` takes the surface's `renderer_state` mutex
    /// (to ask whether the cursor is at a prompt). The autosave tick evaluates this for
    /// every terminal on the main thread, so a renderer or io thread wedged while holding
    /// that mutex parked the main thread forever (#6381). This variant never takes the
    /// mutex: it keeps the same process-risk gate as ``needsConfirmClose()`` and then
    /// reads `child_exited` via `ghostty_surface_process_exited`, which is a plain field
    /// read.
    ///
    /// Trade-off: it cannot see ghostty's OSC 133 prompt state or the
    /// `confirm-close-surface` setting, so a live shell always counts as "needs
    /// confirmation". Snapshots only consult it when cmux has no shell activity report
    /// for the panel, and there the cost is skipping scrollback persistence for that
    /// terminal, never a main-thread hang. Close and quit prompts keep using the
    /// precise ``needsConfirmClose()``.
    public func snapshotNeedsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface, hasCloseConfirmationProcessRisk(surface) else { return false }
        return !ghostty_surface_process_exited(surface)
    }
}
