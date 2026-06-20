import AppKit

/// What an inline-rename field-editor keystroke means. Pure and UI-free so it
/// can be unit-tested without launching the app (mirrors
/// `SidebarTabDropIndicatorPredicate`).
enum SidebarInlineRenameAction: Equatable {
    case commit
    case caretToStart
    case cancel
    case passThrough
}

/// Resolves AppKit field-editor command selectors into inline-rename actions.
/// Two-stage Escape: first Escape (selection present) moves the caret to the
/// start; a second Escape (selection collapsed) cancels.
struct SidebarInlineRenameKeyResolver {
    func action(for selector: Selector, selectionIsCollapsed: Bool) -> SidebarInlineRenameAction {
        // STUB — replaced in Step 5 (green).
        .passThrough
    }
}

/// Normalizes an inline-rename draft before persistence. Trimmed-empty input
/// returns `nil`, which the caller treats as "no change" (the inline editor
/// never clears an existing custom title — design spec §6.1).
enum SidebarInlineRenameCommit {
    static func normalized(_ draft: String) -> String? {
        // STUB — replaced in Step 5 (green).
        draft
    }
}
