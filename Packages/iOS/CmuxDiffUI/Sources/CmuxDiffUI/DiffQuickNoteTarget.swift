struct DiffQuickNoteTarget: Identifiable, Sendable, Equatable {
    let id: String
    let path: String
    let oldLineRange: ClosedRange<Int>?
    let newLineRange: ClosedRange<Int>?
    let hunkHeader: String?
    let excerpt: String
}
