import Foundation

/// In-memory ``TerminalDraftStoring``: per-terminal composer drafts that live for
/// the app session.
///
/// Drafts are tiny (a few unsent keystrokes per terminal), so the whole map is a
/// dictionary keyed by the terminal's stable id. An `actor` serializes access, so
/// the type is genuinely `Sendable` and the shell can fire saves without awaiting.
///
/// This store intentionally does NOT persist to disk: drafts survive terminal
/// switches (the feature this PR ships) but not an app kill/relaunch. A
/// disk-backed ``TerminalDraftStoring`` lands separately and replaces this one at
/// the composition root without touching the shell.
public actor InMemoryTerminalDraftStore: TerminalDraftStoring {
    /// The in-memory draft map (terminal id raw string → draft text).
    private var drafts: [String: String] = [:]

    /// Creates an empty store.
    public init() {}

    /// Returns the saved draft for `terminalID`, or `nil` when none is stored.
    public func draft(forTerminalID terminalID: String) async -> String? {
        drafts[terminalID]
    }

    /// Saves `draft` under `terminalID`. A whitespace-only draft deletes the
    /// entry instead, so abandoned blank edits never resurface on a switch back.
    public func saveDraft(_ draft: String, forTerminalID terminalID: String) async {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[terminalID] = nil
        } else {
            drafts[terminalID] = draft
        }
    }

    /// Removes the draft stored under `terminalID` (after a successful send).
    public func clearDraft(forTerminalID terminalID: String) async {
        drafts[terminalID] = nil
    }

    /// Removes every stored draft (the sign-out wipe).
    public func clearAllDrafts() async {
        drafts.removeAll()
    }
}
