import Foundation

/// A live terminal pane. Every terminal in the workspace appears in the Notes
/// tree as a virtual folder row carrying a pointer back to its panel; the
/// pane's attached flat notes and the agent sessions observed in it nest
/// beneath it, so "the note attached to this terminal" has a stable home even
/// before (or without) an agent running there.
struct NotesTreeObservedTerminal: Equatable, Sendable {
    /// The terminal panel's UUID string — the pointer used to focus it.
    var panelId: String
    /// The pane's note anchor (`Workspace.noteAnchorIdsByPanelId`) when one
    /// was minted — links pane-attached flat notes and session records to
    /// this terminal for nesting.
    var anchorId: String?
    /// The tab title at observation time.
    var title: String
    /// The live agent session currently occupying this terminal, when the
    /// latest observation sees one. This is display metadata only; the row
    /// remains a terminal pointer.
    var activeSession: NotesSessionMarker? = nil
}
