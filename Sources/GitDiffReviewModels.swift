import Foundation

nonisolated enum GitDiffReviewFileStatus: Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case unmerged
    case typeChanged
    case unknown(String)

    var label: String {
        switch self {
        case .modified:
            return String(localized: "codeReview.status.modified", defaultValue: "Modified")
        case .added:
            return String(localized: "codeReview.status.added", defaultValue: "Added")
        case .deleted:
            return String(localized: "codeReview.status.deleted", defaultValue: "Deleted")
        case .renamed:
            return String(localized: "codeReview.status.renamed", defaultValue: "Renamed")
        case .copied:
            return String(localized: "codeReview.status.copied", defaultValue: "Copied")
        case .untracked:
            return String(localized: "codeReview.status.untracked", defaultValue: "Untracked")
        case .unmerged:
            return String(localized: "codeReview.status.unmerged", defaultValue: "Unmerged")
        case .typeChanged:
            return String(localized: "codeReview.status.typeChanged", defaultValue: "Type changed")
        case .unknown:
            return String(localized: "codeReview.status.unknown", defaultValue: "Unknown")
        }
    }
}

nonisolated enum GitDiffReviewLineKind: Equatable, Sendable {
    case context
    case addition
    case deletion
    case note
}

nonisolated struct GitDiffReviewLine: Equatable, Sendable {
    let kind: GitDiffReviewLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
}

nonisolated struct GitDiffReviewHunk: Equatable, Sendable {
    let header: String
    let oldStart: Int
    let newStart: Int
    let lines: [GitDiffReviewLine]
}

nonisolated struct GitDiffReviewFile: Identifiable, Equatable, Sendable {
    let path: String
    let oldPath: String?
    let status: GitDiffReviewFileStatus
    let additions: Int
    let deletions: Int
    let hunks: [GitDiffReviewHunk]

    var id: String {
        if let oldPath {
            return "\(oldPath)->\(path)"
        }
        return path
    }
}

nonisolated struct GitDiffReviewSnapshot: Equatable, Sendable {
    let repositoryRoot: String
    let branch: String
    let files: [GitDiffReviewFile]
    let loadedAt: Date

    var additions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    var deletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }
}

nonisolated enum GitDiffReviewLoadError: Error, Equatable, Sendable {
    case missingDirectory(String)
    case notGitRepository(String)
    case commandFailed
    case cancelled

    var displayMessage: String {
        switch self {
        case .missingDirectory:
            return String(localized: "codeReview.error.notLocalDirectory", defaultValue: "Code Review needs a local workspace directory.")
        case .notGitRepository:
            return String(localized: "codeReview.error.notGitRepository", defaultValue: "This directory is not inside a Git repository.")
        case .commandFailed:
            return String(localized: "codeReview.error.gitFailed", defaultValue: "Code Review could not read changes for this workspace.")
        case .cancelled:
            return String(localized: "codeReview.error.cancelled", defaultValue: "Diff loading was cancelled.")
        }
    }
}

nonisolated enum GitDiffReviewPhase: Equatable, Sendable {
    case idle
    case loading(rootPath: String)
    case loaded(GitDiffReviewSnapshot)
    case failed(rootPath: String, error: GitDiffReviewLoadError)
}
