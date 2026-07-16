enum FileDiffLoadState: Equatable {
    case loading
    case loaded(FileDiffDocument)
    case failed
}
