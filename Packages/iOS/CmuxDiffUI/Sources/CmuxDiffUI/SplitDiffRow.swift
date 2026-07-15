struct SplitDiffRow: Identifiable, Sendable, Equatable {
    let id: String
    let kind: SplitDiffRowKind
    let old: DiffRowSnapshot?
    let new: DiffRowSnapshot?
    let spanning: DiffRowSnapshot?
}
