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
/// Two-stage Escape counts presses: the first Escape moves the caret to the
/// start (`hasMovedCaretToStart` becomes true); any subsequent Escape cancels.
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
    /// write. `baseline` and `baselineHadCustomTitle` are snapshots captured
    /// when editing began (not live values read at commit time), so an
    /// auto-rename that fires mid-edit cannot change the decision. Skips when
    /// the draft is empty/whitespace (never clears an existing custom title) and
    /// when the user committed the unchanged baseline of a workspace that had no
    /// custom title — writing it would convert an auto title into a user title
    /// and freeze auto-naming.
    static func titleToCommit(draft: String, baseline: String, baselineHadCustomTitle: Bool) -> String? {
        guard let normalizedDraft = normalized(draft) else { return nil }
        if !baselineHadCustomTitle, normalizedDraft == normalized(baseline) { return nil }
        return normalizedDraft
    }
}
