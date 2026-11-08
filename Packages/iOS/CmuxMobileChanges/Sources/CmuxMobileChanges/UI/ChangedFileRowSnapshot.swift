/// Immutable identity and file payload passed below the list boundary.
struct ChangedFileRowSnapshot: Identifiable, Sendable, Equatable {
    let index: Int
    let file: ChangedFileItem

    var id: String { file.path }
}
