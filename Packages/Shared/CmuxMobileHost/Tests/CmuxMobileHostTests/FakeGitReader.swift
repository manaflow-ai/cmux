import CmuxMobileHost
import CmuxMobileWire
import Foundation

/// A session host stand-in: answers `git.status` with a fixed repository
/// root and `git.diff` with canned files, and records every call.
actor FakeGitReader: MobileGitReader {
    var root: String
    var files: [GitChangedFile]
    var failure: (any Error)?
    private(set) var calls: [(String, JSONValue)] = []

    init(root: String, files: [GitChangedFile] = [], failure: (any Error)? = nil) {
        self.root = root
        self.files = files
        self.failure = failure
    }

    func read(_ operation: String, params: JSONValue) async throws -> JSONValue {
        calls.append((operation, params))
        if let failure { throw failure }
        switch operation {
        case "git.status":
            return try JSONValue(encoding: GitStatusResult(root: root, branch: "main", head: "abc123", ahead: 1))
        default:
            let request = try params.decode(as: GitDiffParams.self)
            var files = files
            if request.includePatch != true { files = files.map { var f = $0; f.patch = nil; return f } }
            return try JSONValue(encoding: GitDiffResult(
                scope: request.scope, root: root, head: "abc123", files: files,
                additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions },
                totalFiles: files.count))
        }
    }

    func lastDiffParams() throws -> GitDiffParams? {
        try calls.last { $0.0 == "git.diff" }.map { try $0.1.decode(as: GitDiffParams.self) }
    }
}
