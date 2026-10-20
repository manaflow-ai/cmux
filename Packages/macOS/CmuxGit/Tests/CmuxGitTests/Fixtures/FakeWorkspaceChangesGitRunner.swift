import Foundation
@testable import CmuxGit

struct FakeWorkspaceChangesGitRunner: WorkspaceChangesGitRunning {
    let results: [[String]: WorkspaceChangesGitResult]
    let beforeRun: @Sendable ([String], URL) throws -> Void

    init(
        results: [[String]: WorkspaceChangesGitResult],
        beforeRun: @escaping @Sendable ([String], URL) throws -> Void = { _, _ in }
    ) {
        self.results = results
        self.beforeRun = beforeRun
    }

    func run(arguments: [String], in directory: URL) throws -> WorkspaceChangesGitResult {
        try beforeRun(arguments, directory)
        return results[arguments] ?? WorkspaceChangesGitResult(output: Data(), exitCode: 1)
    }

    static func result(_ output: String = "", exitCode: Int32 = 0) -> WorkspaceChangesGitResult {
        WorkspaceChangesGitResult(output: Data(output.utf8), exitCode: exitCode)
    }
}
