import Foundation

enum DiffReviewLineKind: Equatable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

struct DiffReviewLine: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: DiffReviewLineKind
    let marker: String
    let text: String
}

enum DiffReviewFileStatus: String, Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case binary
}

struct DiffReviewHunk: Identifiable, Equatable, Sendable {
    let id: String
    let header: String
    let oldStart: Int
    let oldLength: Int
    let newStart: Int
    let newLength: Int
    let sectionHeading: String?
    let lines: [DiffReviewLine]
    let patch: String
    let addedLineCount: Int
    let deletedLineCount: Int
}

struct DiffReviewFile: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let oldPath: String?
    let status: DiffReviewFileStatus
    let hunks: [DiffReviewHunk]
    let addedLineCount: Int
    let deletedLineCount: Int
}

enum DiffReviewTarget: Equatable, Identifiable, Sendable {
    case workingTree
    case branch(String)

    static let workingTreeID = "working-tree"

    var id: String {
        switch self {
        case .workingTree:
            return Self.workingTreeID
        case .branch(let branchName):
            return "branch:\(branchName)"
        }
    }

    var branchName: String? {
        guard case .branch(let branchName) = self else { return nil }
        return branchName
    }

    var allowsHunkRevert: Bool {
        switch self {
        case .workingTree:
            return true
        case .branch:
            return false
        }
    }

    static func from(id: String, branches: [String]) -> DiffReviewTarget {
        if id == Self.workingTreeID {
            return .workingTree
        }
        if id.hasPrefix("branch:") {
            let branchName = String(id.dropFirst("branch:".count))
            if branches.contains(branchName) {
                return .branch(branchName)
            }
        }
        return .workingTree
    }
}

struct DiffReviewSnapshot: Equatable, Sendable {
    let repositoryRoot: String
    let currentBranch: String?
    let branches: [String]
    let selectedTarget: DiffReviewTarget
    let files: [DiffReviewFile]
    let generatedAt: Date

    var targets: [DiffReviewTarget] {
        [.workingTree] + branches.map(DiffReviewTarget.branch)
    }

    var totalAddedLineCount: Int {
        files.reduce(0) { $0 + $1.addedLineCount }
    }

    var totalDeletedLineCount: Int {
        files.reduce(0) { $0 + $1.deletedLineCount }
    }
}

enum DiffReviewLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

enum DiffReviewPanelContentState: Equatable {
    case noWorkspace
    case loading
    case error(String)
    case files(DiffReviewSnapshot)

    static func resolve(
        directory: String?,
        snapshot: DiffReviewSnapshot?,
        phase: DiffReviewLoadPhase
    ) -> DiffReviewPanelContentState {
        if directory == nil {
            return .noWorkspace
        }
        if case .failed(let message) = phase {
            return .error(message)
        }
        if let snapshot {
            return .files(snapshot)
        }
        return .loading
    }
}
