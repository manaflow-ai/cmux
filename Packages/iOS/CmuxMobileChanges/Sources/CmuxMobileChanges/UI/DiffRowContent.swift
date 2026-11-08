/// The mutually exclusive content rendered by one flat diff row.
enum DiffRowContent: Sendable, Equatable {
    case line(DiffLine, hunkCopyText: String)
    case expander(DiffExpanderSnapshot)
}
