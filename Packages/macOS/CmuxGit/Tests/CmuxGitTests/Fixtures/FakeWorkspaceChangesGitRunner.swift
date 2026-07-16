import Foundation
@testable import CmuxGit

struct FakeWorkspaceChangesGitRunner: WorkspaceChangesGitRunning {
    let results: [[String]: WorkspaceChangesGitResult]

    func run(arguments: [String], in directory: URL) throws -> WorkspaceChangesGitResult {
        results[arguments] ?? WorkspaceChangesGitResult(output: Data(), exitCode: 1)
    }

    static func result(_ output: String = "", exitCode: Int32 = 0) -> WorkspaceChangesGitResult {
        WorkspaceChangesGitResult(output: Data(output.utf8), exitCode: exitCode)
    }
}
