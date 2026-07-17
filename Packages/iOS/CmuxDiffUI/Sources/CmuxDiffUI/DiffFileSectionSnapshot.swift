struct DiffFileSectionSnapshot: Identifiable, Sendable, Equatable {
    var id: String { state.id }
    let state: DiffFilePresentationState
    let highlights: [String: HighlightedCode]
}
