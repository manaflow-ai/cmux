import Foundation

/// Normalizes an inline-rename draft before persistence. Trimmed-empty input
/// returns `nil`, which the caller treats as "no change" (the inline editor
/// never clears an existing custom title).
enum SidebarInlineRenameCommit {
    static func normalized(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The title to persist for an inline-rename commit, or `nil` to skip the
    /// write. `baseline` and `baselineHadUserCustomTitle` are snapshots captured
    /// when editing began (not live values read at commit time), so an
    /// auto-rename that fires mid-edit cannot change the decision. Skips when
    /// the draft is empty/whitespace (never clears an existing custom title) and
    /// when the user committed the unchanged baseline of a workspace that had no
    /// user-owned custom title; writing it would convert an automatic title into
    /// a user title and freeze auto-naming.
    static func titleToCommit(draft: String, baseline: String, baselineHadUserCustomTitle: Bool) -> String? {
        guard let normalizedDraft = normalized(draft) else { return nil }
        if !baselineHadUserCustomTitle, normalizedDraft == normalized(baseline) { return nil }
        return normalizedDraft
    }
}
