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
}
