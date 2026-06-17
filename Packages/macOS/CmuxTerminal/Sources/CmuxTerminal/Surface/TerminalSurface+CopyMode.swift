public import Foundation
public import GhosttyKit
internal import Darwin

// MARK: - Binding actions, keyboard copy mode, selection

extension TerminalSurface {
    /// Performs a Ghostty binding action string on the runtime surface.
    ///
    /// - Returns: Whether the runtime performed the action.
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    /// Toggles keyboard copy mode through the surface view.
    ///
    /// - Returns: Whether the view handled the toggle.
    @discardableResult
    @MainActor
    public func toggleKeyboardCopyMode() -> Bool {
        let handled = surfaceView.toggleKeyboardCopyMode()
        if handled {
            setKeyboardCopyModeActive(surfaceView.isKeyboardCopyModeActive)
        }
        return handled
    }

    /// Mirrors the view's copy-mode state and syncs the key-state indicator.
    ///
    /// Isolation note: the legacy entry accepted off-main callers with a
    /// Thread.isMainThread check + main-queue hop; every caller (the surface
    /// view's copy-mode toggle paths and this model) runs on the main actor,
    /// so the hop was dead and the method is now @MainActor.
    @MainActor
    public func setKeyboardCopyModeActive(_ active: Bool) {
        if keyboardCopyModeActive != active {
            keyboardCopyModeActive = active
        }
        paneHost.syncKeyStateIndicator(text: surfaceView.currentKeyStateIndicatorText)
    }

    /// Whether the runtime surface has an active selection.
    public func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }
}
