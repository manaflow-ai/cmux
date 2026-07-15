struct DiffFilePresentationState: Identifiable, Sendable, Equatable {
    var id: String { file.id }
    let file: DiffFileSnapshot
    var isViewed: Bool
    var isCollapsed: Bool
    let rows: [DiffRowSnapshot]
    let splitRows: [SplitDiffRow]
}
