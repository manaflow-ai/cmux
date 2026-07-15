struct DiffTreeRowSnapshot: Identifiable, Sendable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let depth: Int
    let kind: DiffTreeRowKind
    let additions: Int
    let deletions: Int
    let fileCount: Int
    let isViewed: Bool
}
