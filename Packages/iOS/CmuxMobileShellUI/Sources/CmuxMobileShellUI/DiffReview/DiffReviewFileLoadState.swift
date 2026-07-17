import CmuxDiffModel

enum DiffReviewFileLoadState {
    case empty
    case idle
    case loading(path: String)
    case loaded(path: String, hunks: [DiffHunk], metadataLines: [String], isTruncated: Bool)
    case failed(path: String, message: String)

    func visible(for path: String?) -> Self {
        guard let path else { return .empty }
        switch self {
        case .empty, .idle:
            return .loading(path: path)
        case .loading(let loadedPath),
            .loaded(let loadedPath, _, _, _),
            .failed(let loadedPath, _):
            return loadedPath == path ? self : .loading(path: path)
        }
    }
}
