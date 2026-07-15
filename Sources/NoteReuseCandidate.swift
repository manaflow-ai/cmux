import Foundation

/// Main-thread snapshot of a markdown panel's note identity, taken while
/// resolving `note.create` / `note.open` (TerminalController+Notes.swift) so
/// an existing panel showing the same note is refocused instead of spawning
/// a duplicate split.
struct NoteReuseCandidate {
    let panelId: UUID
    let filePath: String
    let noteID: String?
    let noteBodyPath: String?
}
