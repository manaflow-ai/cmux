import AppKit

/// Resolves AppKit field-editor command selectors into inline-rename actions.
/// Two-stage Escape counts presses: the first Escape moves the caret to the
/// start (`hasMovedCaretToStart` becomes true); any subsequent Escape cancels.
struct SidebarInlineRenameKeyResolver {
    /// Maps an AppKit field-editor command `selector` to a rename action,
    /// applying the press-count Escape rule via `hasMovedCaretToStart`.
    func action(for selector: Selector, hasMovedCaretToStart: Bool) -> SidebarInlineRenameAction {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return .commit
        case #selector(NSResponder.cancelOperation(_:)):
            return hasMovedCaretToStart ? .cancel : .caretToStart
        default:
            return .passThrough
        }
    }
}
