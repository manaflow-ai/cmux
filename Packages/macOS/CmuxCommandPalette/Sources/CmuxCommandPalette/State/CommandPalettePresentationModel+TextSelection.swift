import Foundation

extension CommandPalettePresentationModel {
    /// Resolves whether the queued ``pendingTextSelectionBehavior`` applies in the
    /// current ``mode``, returning the selection the host should apply to the live
    /// field editor.
    ///
    /// This is the pure gating half of the legacy
    /// `attemptCommandPaletteTextSelectionIfNeeded`: it reproduces, case for case,
    /// which behavior is permitted in which mode. It performs no mutation (it does
    /// not clear ``pendingTextSelectionBehavior``) and reads no AppKit state, so
    /// the host keeps ownership of the field-editor lookup, the actual
    /// `setSelectedRange`, and the post-apply clear.
    ///
    /// Faithful gating, matching the legacy body exactly:
    /// - No pending behavior queued: ``CommandPaletteTextSelectionPlan/skip``.
    /// - `.selectAll` applies only in ``CommandPaletteMode/renameInput(_:)``;
    ///   otherwise `skip`.
    /// - `.caretAtEnd` applies in ``CommandPaletteMode/commands`` and
    ///   ``CommandPaletteMode/renameInput(_:)``; it is skipped in
    ///   ``CommandPaletteMode/renameConfirm(_:proposedName:)`` and
    ///   ``CommandPaletteMode/workspaceDescriptionInput(_:)``.
    ///
    /// - Returns: the selection to apply, or ``CommandPaletteTextSelectionPlan/skip``
    ///   when the queued behavior must stay pending for a later focus. The caller
    ///   clears ``pendingTextSelectionBehavior`` only after it actually applies a
    ///   non-`skip` plan to a field editor, exactly as the legacy code did.
    public func pendingTextSelectionPlan() -> CommandPaletteTextSelectionPlan {
        guard let behavior = pendingTextSelectionBehavior else { return .skip }
        switch behavior {
        case .selectAll:
            guard case .renameInput = mode else { return .skip }
            return .selectAll
        case .caretAtEnd:
            switch mode {
            case .commands, .renameInput:
                return .caretAtEnd
            case .renameConfirm:
                return .skip
            case .workspaceDescriptionInput:
                return .skip
            }
        }
    }
}
