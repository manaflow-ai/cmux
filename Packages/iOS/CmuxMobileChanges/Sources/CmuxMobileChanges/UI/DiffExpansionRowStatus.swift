/// Fetch and retry presentation state for one diff expander band.
enum DiffExpansionRowStatus: Equatable {
    case ready
    case loading(DiffExpansionDirection)
    case failed(DiffExpansionDirection)
    case tooLarge
}
