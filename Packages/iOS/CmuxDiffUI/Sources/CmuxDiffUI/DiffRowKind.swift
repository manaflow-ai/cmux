enum DiffRowKind: Sendable, Equatable {
    case hunkHeader
    case context
    case addition
    case deletion
    case noNewline
}
