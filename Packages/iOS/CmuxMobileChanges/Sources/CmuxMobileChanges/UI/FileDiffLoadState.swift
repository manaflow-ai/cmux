enum FileDiffLoadState: Equatable {
    case loading
    case loaded(FileDiffPresentation)
    case failed
}
