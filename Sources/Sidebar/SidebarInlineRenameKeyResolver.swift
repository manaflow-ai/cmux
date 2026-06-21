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

/// Normalizes an inline-rename draft before persistence. Trimmed-empty input
/// returns `nil`, which the caller treats as "no change" (the inline editor
/// never clears an existing custom title — design spec §6.1).
enum SidebarInlineRenameCommit {
    static func normalized(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The title to persist for an inline-rename commit, or `nil` to skip the
    /// write. Skips when the draft is empty/whitespace (never clears an existing
    /// custom title) and when committing the current process title to a
    /// workspace that has no custom title — writing it would convert an auto
    /// title into a user title and freeze auto-naming.
    static func titleToCommit(draft: String, currentTitle: String, hasCustomTitle: Bool) -> String? {
        guard let normalized = normalized(draft) else { return nil }
        if !hasCustomTitle && normalized == currentTitle { return nil }
        return normalized
    }
}
