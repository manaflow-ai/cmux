/// The `attach` parameter values accepted by the `note.create` / `note.open`
/// socket RPCs (TerminalController+Notes.swift).
enum NoteRPCAttachMode: String {
    case none
    case workspace
    case surface
    case terminal
}
