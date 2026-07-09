public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
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

    /// Reads the runtime surface's current text selection into a value snapshot.
    ///
    /// Returns `nil` when there is no live surface or the runtime reports no
    /// selection. The accessibility text-area exposure and the
    /// `NSTextInputClient` selection/substring/coordinate methods consume this.
    /// Lifted verbatim from the view-private `readSelectionSnapshot()`.
    public func readRuntimeSelectionSnapshot() -> TerminalRuntimeSelectionSnapshot? {
        guard let surface else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let selected: String
        if let ptr = text.text, text.text_len > 0 {
            let selectedData = Data(bytes: ptr, count: Int(text.text_len))
            selected = String(decoding: selectedData, as: UTF8.self)
        } else {
            selected = ""
        }

        return TerminalRuntimeSelectionSnapshot(
            range: NSRange(location: Int(text.offset_start), length: Int(text.offset_len)),
            string: selected,
            topLeft: CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        )
    }
}
