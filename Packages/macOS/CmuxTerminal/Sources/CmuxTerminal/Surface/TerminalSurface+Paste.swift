// MARK: - Clipboard paste

extension TerminalSurface {
    /// Pastes the standard clipboard contents into the runtime surface.
    ///
    /// Records the paste as agent-hibernation terminal input, then performs the
    /// Ghostty `paste_from_clipboard` binding action. The flavor-priority and
    /// rich-text resolution rules are applied by the pasteboard service when the
    /// runtime reads the clipboard during the binding action.
    ///
    /// - Returns: Whether the runtime performed the paste binding action.
    @MainActor
    @discardableResult
    public func pasteFromClipboard() -> Bool {
        hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        return performBindingAction("paste_from_clipboard")
    }
}
