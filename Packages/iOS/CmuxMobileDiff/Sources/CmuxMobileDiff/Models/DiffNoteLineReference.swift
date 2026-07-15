/// The side-aware line location included in an agent diff note.
struct DiffNoteLineReference: Sendable, Equatable {
    /// One-based line number on the selected side.
    let number: Int
    /// Whether `number` belongs to the old side of a deletion.
    let isOld: Bool

    /// Formats the reference for the unambiguous agent prompt.
    var promptText: String {
        isOld ? "\(number) (old)" : String(number)
    }
}
