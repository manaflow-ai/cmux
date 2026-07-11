import CmuxDiffModel

enum DiffReviewFileLoadState {
    case idle
    case loading(path: String)
    case loaded(path: String, hunks: [DiffHunk], isTruncated: Bool)
    case failed(path: String, message: String)

    func visible(for path: String?) -> Self {
        guard let path else { return .idle }
        switch self {
        case .idle:
            return .loading(path: path)
        case .loading(let loadedPath),
            .loaded(let loadedPath, _, _),
            .failed(let loadedPath, _):
            return loadedPath == path ? self : .loading(path: path)
        }
    }
}
